/*
 * bcrypt_pbkdf — OpenBSD bcrypt_pbkdf.c (Ted Unangst, ISC 라이선스) 를 따라 옮김.
 * SHA-512 는 애플 CommonCrypto, Blowfish 는 blf.c (Niels Provos, BSD).
 *
 * Copyright (c) 2013 Ted Unangst <tedu@openbsd.org>
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 */
#include <stdlib.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#include "blf.h"
#include "bcrypt_pbkdf.h"

#define BCRYPT_WORDS 8
#define BCRYPT_HASHSIZE (BCRYPT_WORDS * 4)
#define SHA512_LEN CC_SHA512_DIGEST_LENGTH

static void sha512(uint8_t *out, const void *in, size_t len) { CC_SHA512(in, (CC_LONG)len, out); }

static void bcrypt_hash(const uint8_t *sha2pass, const uint8_t *sha2salt, uint8_t *out) {
    blf_ctx state;
    uint8_t ciphertext[BCRYPT_HASHSIZE] = "OxychromaticBlowfishSwatDynamite";
    uint32_t cdata[BCRYPT_WORDS];
    uint16_t j = 0;
    ivnc_Blowfish_initstate(&state);
    ivnc_Blowfish_expandstate(&state, sha2salt, SHA512_LEN, sha2pass, SHA512_LEN);
    for (int i = 0; i < 64; i++) {
        ivnc_Blowfish_expand0state(&state, sha2salt, SHA512_LEN);
        ivnc_Blowfish_expand0state(&state, sha2pass, SHA512_LEN);
    }
    for (int i = 0; i < BCRYPT_WORDS; i++)
        cdata[i] = ivnc_Blowfish_stream2word(ciphertext, sizeof(ciphertext), &j);
    for (int i = 0; i < 64; i++)
        ivnc_blf_enc(&state, cdata, BCRYPT_WORDS / 2);
    for (int i = 0; i < BCRYPT_WORDS; i++) {
        out[4 * i + 3] = (cdata[i] >> 24) & 0xff;
        out[4 * i + 2] = (cdata[i] >> 16) & 0xff;
        out[4 * i + 1] = (cdata[i] >> 8) & 0xff;
        out[4 * i + 0] = cdata[i] & 0xff;
    }
    memset(cdata, 0, sizeof(cdata));
    memset(&state, 0, sizeof(state));
}

int ivnc_bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                      uint8_t *key, size_t keylen, unsigned int rounds) {
    uint8_t sha2pass[SHA512_LEN], sha2salt[SHA512_LEN];
    uint8_t out[BCRYPT_HASHSIZE], tmpout[BCRYPT_HASHSIZE];
    size_t origkeylen = keylen;
    if (rounds < 1 || passlen == 0 || saltlen == 0 || keylen == 0 ||
        keylen > sizeof(out) * sizeof(out) || saltlen > (1 << 20)) return -1;
    uint8_t *countsalt = calloc(1, saltlen + 4);
    if (!countsalt) return -1;
    size_t stride = (keylen + sizeof(out) - 1) / sizeof(out);
    size_t amt = (keylen + stride - 1) / stride;
    memcpy(countsalt, salt, saltlen);
    sha512(sha2pass, pass, passlen);
    for (uint32_t count = 1; keylen > 0; count++) {
        countsalt[saltlen + 0] = (count >> 24) & 0xff;
        countsalt[saltlen + 1] = (count >> 16) & 0xff;
        countsalt[saltlen + 2] = (count >> 8) & 0xff;
        countsalt[saltlen + 3] = count & 0xff;
        sha512(sha2salt, countsalt, saltlen + 4);
        bcrypt_hash(sha2pass, sha2salt, tmpout);
        memcpy(out, tmpout, sizeof(out));
        for (unsigned int i = 1; i < rounds; i++) {
            sha512(sha2salt, tmpout, sizeof(tmpout));
            bcrypt_hash(sha2pass, sha2salt, tmpout);
            for (size_t j = 0; j < sizeof(out); j++) out[j] ^= tmpout[j];
        }
        // 출력을 섞어 놓는다 (모든 출력이 모든 라운드에 의존하도록)
        if (amt > keylen) amt = keylen;
        size_t i;
        for (i = 0; i < amt; i++) {
            size_t dest = i * stride + (count - 1);
            if (dest >= origkeylen) break;
            key[dest] = out[i];
        }
        keylen -= i;
    }
    free(countsalt);
    memset(out, 0, sizeof(out));
    memset(tmpout, 0, sizeof(tmpout));
    memset(sha2pass, 0, sizeof(sha2pass));
    return 0;
}
