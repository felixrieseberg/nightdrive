#ifndef CAudioTapRing_h
#define CAudioTapRing_h

#include <stdbool.h>
#include <stddef.h>

typedef struct CWAudioTapRing CWAudioTapRing;

CWAudioTapRing *CWAudioTapRingCreate(size_t capacity);
void CWAudioTapRingDestroy(CWAudioTapRing *ring);

void CWAudioTapRingPush(CWAudioTapRing *ring, const float *samples, size_t count);

bool CWAudioTapRingSnapshot(
    const CWAudioTapRing *ring, float *output, size_t outputCapacity);

void CWAudioTapRingReset(CWAudioTapRing *ring);

#endif
