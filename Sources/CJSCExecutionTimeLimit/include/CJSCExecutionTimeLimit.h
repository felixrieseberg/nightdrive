#ifndef CJSCExecutionTimeLimit_h
#define CJSCExecutionTimeLimit_h

#include <JavaScriptCore/JavaScriptCore.h>


typedef bool (*CJSCShouldTerminateCallback)(JSContextRef ctx, void *context);

bool CJSCExecutionTimeLimitAvailable(void);

bool CJSCSetExecutionTimeLimit(JSContextGroupRef group, double limitSeconds,
                               CJSCShouldTerminateCallback callback, void *context);

#endif
