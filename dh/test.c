#include <stdio.h>
#include <gmp.h>
#include "openssl/sha.h"
#include <openssl/evp.h>

// shared secret
static const char* PRIME_HEX =
  "00f2b2ab9d7b23c84f9f0ec2f3bc40c5c4ec"
  "4764a7c3d01449662620dd43f3d97a64515a"
  "2af5b3c8e3f224b8d18d07b6b62261200ad8"
  "48f5ff8ac19a1b7343994de846de69c1c2ee"
  "5e62fe4ed374e685e486f1b897d72d01df5c"
  "99ae72b8e9a31777ccaa11a5ae6ca08cfc81"
  "0269337660248d0be9b8214ecdd4656f207d"
  "2977a7364e443acf431af76aead7224f86a0"
  "3eb9998692acebd50c558ce9a7fefc37ab24"
  "2f0c19b51a0167d5dae94b853210f6f492a9"
  "bbb39ad809396b44a299bd85acafdfedbc4d"
  "21ae2ec307ab3dab09d799c6011c41cf813d"
  "621ef205cf2276d0cf7acf09108e14a8b8dd"
  "e1ee2045deaebdb529dbd187d4ee4b30a946"
  "58b156ac33";

static unsigned int BASE = 2;

unsigned int readPayloadSize();
void writePayloadSize(unsigned int);

int main(void) {
  // gmp_printf doesn't appear to flush on its own, and I don't want to have to
  // remember it each time
  setbuf(stdout, NULL);

  mpz_t prime, base, server_private, server_public, client_public, session_id;
  gmp_randstate_t randstate;

  // load constants into mpz values
  mpz_init_set_str(prime, PRIME_HEX, 16);
  mpz_init_set_ui(base, BASE);

  // initialize PRNG
  gmp_randinit_default(randstate);

  // generate random server private key
  mpz_init(server_private);
  mpz_urandomm(server_private, randstate, prime);

  // calculate server public key
  mpz_init(server_public);
  mpz_powm(server_public, base, server_private, prime);

  // receive hello and client public key
  char buffer[1024];
  fgets(buffer, 1024, stdin); // throw away: "SimpleSSLv0"
  fgets(buffer, 1024, stdin);
  mpz_init(client_public);
  gmp_sscanf(buffer, "%Zx", client_public);

  // send OK and server public key
  gmp_printf("OK\n%Zx\n", server_public);

  // calculate session id
  mpz_init(session_id);
  mpz_powm(session_id, client_public, server_private, prime);

  // pack session id into 257 bytes of data (session_id_data has 264 bytes to
  // be a multiple of chunk_bytes (8); bytes 0 through 6 will be ignored as we
  // use the back-end 257 bytes
  size_t chunk_bytes = sizeof(unsigned int);
  mp_bitcnt_t chunk_bits = 8 * chunk_bytes;
  char pack_data[264];
  unsigned int *chunk = (unsigned int *) (pack_data + 264) - 1;
  for (; (char*) chunk >= pack_data; chunk--) {
    // read 4 bytes worth
    *chunk = mpz_get_ui(session_id);

    // these four bytes still need to be swapped around
    char a, b;
    a = *((char*)chunk);
    b = *((char*)chunk + 1);
    *((char*)chunk) = *((char*)chunk + 3);
    *((char*)chunk + 1) = *((char*)chunk + 2);
    *((char*)chunk + 2) = b;
    *((char*)chunk + 3) = a;

    // shift the remaining number down by those 32 bits
    mpz_tdiv_q_2exp(session_id, session_id, chunk_bits);
  }
  char *session_id_data = pack_data + 7;

  // hash the packed session id into the session key (we'll only use the first
  // 128 bits, despite SHA256_DIGEST_LENGTH)
  unsigned char session_key[SHA256_DIGEST_LENGTH];
  SHA256_CTX sha256;
  SHA256_Init(&sha256);
  SHA256_Update(&sha256, session_id_data, 257);
  SHA256_Final(session_key, &sha256);

  // initial nonces
  unsigned char recv_iv[12] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
  unsigned char send_iv[12] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

  while (1) {
    // determine payload size of next message
    unsigned int payloadSize = readPayloadSize();
    if (payloadSize == 0) break;

    // copy out
    writePayloadSize(payloadSize);

    // discount actual payload size for GCM tag
    payloadSize -= 16;

    // set up new decrypt/encrypt contexts
    EVP_CIPHER_CTX *decryptCtx = EVP_CIPHER_CTX_new();
    EVP_DecryptInit_ex(decryptCtx, EVP_aes_128_gcm(), NULL, NULL, NULL);
    EVP_DecryptInit_ex(decryptCtx, NULL, NULL, session_key, recv_iv);

    EVP_CIPHER_CTX *encryptCtx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(encryptCtx, EVP_aes_128_gcm(), NULL, NULL, NULL);
    EVP_EncryptInit_ex(encryptCtx, NULL, NULL, session_key, send_iv);

    // decrypt/encrypt in chunks
    char ct[1024];
    char pt[1024];
    int n;
    while (payloadSize > 1024) {
      fread(ct, 1, 1024, stdin);
      payloadSize -= 1024;
      EVP_DecryptUpdate(decryptCtx, pt, &n, ct, 1024);
      EVP_EncryptUpdate(encryptCtx, ct, &n, pt, 1024);
      fwrite(ct, 1, 1024, stdout);
    }

    // last chunk
    fread(ct, 1, payloadSize, stdin);
    EVP_DecryptUpdate(decryptCtx, pt, &n, ct, payloadSize);
    EVP_EncryptUpdate(encryptCtx, ct, &n, pt, payloadSize);
    fwrite(ct, 1, payloadSize, stdout);

    // read GCM tag
    unsigned char tag[16];
    fread(tag, 1, 16, stdin);

    // verify decryption with GCM tag
    EVP_CIPHER_CTX_ctrl(decryptCtx, EVP_CTRL_GCM_SET_TAG, 16, tag);
    EVP_DecryptFinal_ex(decryptCtx, pt, &n);
    EVP_CIPHER_CTX_free(decryptCtx);

    // finalize encryption and extract GCM tag
    EVP_EncryptFinal_ex(encryptCtx, ct, &n);
    EVP_CIPHER_CTX_ctrl(encryptCtx, EVP_CTRL_GCM_GET_TAG, 16, tag);
    EVP_CIPHER_CTX_free(encryptCtx);

    // write GCM tag
    fwrite(tag, 1, 16, stdout);

    // advance nonces for next message (I doubt they'll test more than 2^32
    // messages)
    int idx = 11;
    while (idx >= 0) {
      recv_iv[idx]--;
      send_iv[idx]++;
      // no overflow, done
      if (send_iv[idx] > 0) break;
      idx--;
    }
  }

  // free used memory
  mpz_clear(prime);
  mpz_clear(base);
  mpz_clear(server_private);
  mpz_clear(server_public);
  mpz_clear(client_public);
  mpz_clear(session_id);

  return 0;
}

unsigned int readPayloadSize() {
  char buffer[4] = { 0x00 };
  size_t n = fread(buffer, 1, 4, stdin);
  char a, b;
  a = buffer[0];
  b = buffer[1];
  buffer[0] = buffer[3];
  buffer[1] = buffer[2];
  buffer[2] = b;
  buffer[3] = a;
  return *((unsigned int *)buffer);
}

void writePayloadSize(unsigned int size) {
  char buffer[4] = { 0x00 };
  *((unsigned int *)buffer) = size;
  char a, b;
  a = buffer[0];
  b = buffer[1];
  buffer[0] = buffer[3];
  buffer[1] = buffer[2];
  buffer[2] = b;
  buffer[3] = a;
  size_t n = fwrite(buffer, 1, 4, stdout);
}
