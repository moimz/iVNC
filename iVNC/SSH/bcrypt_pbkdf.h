// OpenSSH 개인 키(openssh-key-v1)의 암호를 키로 바꾸는 bcrypt_pbkdf (OpenBSD bcrypt_pbkdf.c 를 따름, Blowfish 는 blf.c)
#ifndef IVNC_BCRYPT_PBKDF_H
#define IVNC_BCRYPT_PBKDF_H
#include <stddef.h>
#include <stdint.h>

/// 성공 0, 실패 -1
int ivnc_bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                      uint8_t *key, size_t keylen, unsigned int rounds);
#endif
