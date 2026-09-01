#include "CJSCExecutionTimeLimit.h"

// Weak-link JavaScriptCore's private watchdog API to preserve app startup.
extern void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group,
                                                double limit,
                                                CJSCShouldTerminateCallback callback,
                                                void *context)
    __attribute__((weak_import));

bool CJSCExecutionTimeLimitAvailable(void) {
  return JSContextGroupSetExecutionTimeLimit != NULL;
}

bool CJSCSetExecutionTimeLimit(JSContextGroupRef group, double limitSeconds,
                               CJSCShouldTerminateCallback callback, void *context) {
  if (JSContextGroupSetExecutionTimeLimit == NULL) {
    return false;
  }
  JSContextGroupSetExecutionTimeLimit(group, limitSeconds, callback, context);
  return true;
}
