// FreeRDP 를 Swift 에서 쓰기 위한 얇은 C 다리. Swift 는 FreeRDP 헤더(매크로·구조체)를 직접 보지 않고 이 함수들만 본다.
#ifndef RDPBridge_h
#define RDPBridge_h

/// 링크 확인용: FreeRDP 버전 문자열 (예: "3.33.1")
const char *ivnc_freerdp_version(void);

#endif
