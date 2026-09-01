#include "CAudioTapRing.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The realtime producer requires native lock-free atomics.
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "64-bit audio ring atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2,
               "32-bit audio ring atomics must be lock-free");

typedef struct {
  _Atomic uint64_t version;
  _Atomic uint32_t sampleBits;
} CWAudioTapSlot;

struct CWAudioTapRing {
  size_t capacity;
  _Atomic uint64_t reservedCount;
  _Atomic uint64_t publishedCount;
  _Atomic uint64_t resetBoundary;
  CWAudioTapSlot slots[];
};

CWAudioTapRing *CWAudioTapRingCreate(size_t capacity) {
  if (capacity == 0 ||
      capacity > (SIZE_MAX - sizeof(CWAudioTapRing)) / sizeof(CWAudioTapSlot)) {
    return NULL;
  }
  CWAudioTapRing *ring = calloc(
      1, sizeof(CWAudioTapRing) + capacity * sizeof(CWAudioTapSlot));
  if (ring == NULL) {
    return NULL;
  }
  ring->capacity = capacity;
  atomic_init(&ring->reservedCount, 0);
  atomic_init(&ring->publishedCount, 0);
  atomic_init(&ring->resetBoundary, 0);
  for (size_t index = 0; index < capacity; index++) {
    atomic_init(&ring->slots[index].version, 0);
    atomic_init(&ring->slots[index].sampleBits, 0);
  }
  return ring;
}

void CWAudioTapRingDestroy(CWAudioTapRing *ring) {
  free(ring);
}

void CWAudioTapRingPush(CWAudioTapRing *ring, const float *samples, size_t count) {
  if (ring == NULL || samples == NULL || count == 0) {
    return;
  }

  uint64_t firstSequence = atomic_fetch_add(&ring->reservedCount, (uint64_t)count);
  size_t firstInput = count > ring->capacity ? count - ring->capacity : 0;
  for (size_t input = firstInput; input < count; input++) {
    uint64_t sequence = firstSequence + (uint64_t)input;
    CWAudioTapSlot *slot = &ring->slots[sequence % ring->capacity];
    uint64_t writingVersion = sequence * 2 + 1;
    uint32_t bits = 0;
    memcpy(&bits, &samples[input], sizeof(bits));

    // Odd versions mark writes; even versions identify stable samples.
    atomic_store(&slot->version, writingVersion);
    atomic_store(&slot->sampleBits, bits);
    atomic_store(&slot->version, writingVersion + 1);
  }
  atomic_store(&ring->publishedCount, firstSequence + (uint64_t)count);
}

bool CWAudioTapRingSnapshot(
    const CWAudioTapRing *ring, float *output, size_t outputCapacity) {
  if (ring == NULL || output == NULL || outputCapacity != ring->capacity) {
    return false;
  }

  uint64_t resetBefore = atomic_load(&ring->resetBoundary);
  uint64_t end = atomic_load(&ring->publishedCount);
  if (resetBefore >= end) {
    memset(output, 0, outputCapacity * sizeof(float));
    return resetBefore == atomic_load(&ring->resetBoundary);
  }

  uint64_t first = end > ring->capacity ? end - ring->capacity : 0;
  if (first < resetBefore) {
    first = resetBefore;
  }
  size_t sampleCount = (size_t)(end - first);
  size_t outputIndex = outputCapacity - sampleCount;
  memset(output, 0, outputIndex * sizeof(float));

  for (uint64_t sequence = first; sequence < end; sequence++, outputIndex++) {
    const CWAudioTapSlot *slot = &ring->slots[sequence % ring->capacity];
    uint64_t expectedVersion = sequence * 2 + 2;
    uint64_t versionBefore = atomic_load(&slot->version);
    uint32_t bits = atomic_load(&slot->sampleBits);
    uint64_t versionAfter = atomic_load(&slot->version);
    if (versionBefore != expectedVersion || versionAfter != expectedVersion) {
      return false;
    }
    memcpy(&output[outputIndex], &bits, sizeof(bits));
  }

  return resetBefore == atomic_load(&ring->resetBoundary);
}

void CWAudioTapRingReset(CWAudioTapRing *ring) {
  if (ring == NULL) {
    return;
  }
  atomic_store(&ring->resetBoundary, atomic_load(&ring->reservedCount));
}
