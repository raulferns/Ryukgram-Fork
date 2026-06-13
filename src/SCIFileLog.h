#import <Foundation/Foundation.h>

// Shared file logger for RyukGram's own activity — one file across the main app
// and any injected appex. Self-contained (Foundation only) so it also compiles
// into zxPluginsInject.dylib. Process-safe via flock + O_APPEND.
//
// Two gates:
//   • SCI_FILELOG (compile-time) — pass -DSCI_FILELOG=0 for production; the
//     whole thing, the NSLog tee and the Settings row compile out to no-ops.
//   • SCIFileLogSetEnabled (runtime) — OFF by default, marker-file backed so an
//     appex honors the same switch.
//
// Captures NSLog(@"[SCInsta]...") via a prefix-filtered tee, plus explicit
// SCIFLog(category, fmt, ...) lines.

#ifndef SCI_FILELOG
#define SCI_FILELOG 1
#endif

NS_ASSUME_NONNULL_BEGIN

#if SCI_FILELOG

#ifdef __cplusplus
extern "C" {
#endif

void SCIFileLogWrite(NSString * _Nullable category, NSString *message);
NSString * _Nullable SCIFileLogPath(void);
NSURL * _Nullable SCIFileLogURL(void);
void SCIFileLogClear(void);
NSString * _Nullable SCIFileLogExportToDocuments(void);

// Runtime master switch (marker-file backed, cross-process). Default OFF.
void SCIFileLogSetEnabled(BOOL enabled);
BOOL SCIFileLogIsEnabled(void);

#ifdef __cplusplus
}
#endif

#define SCIFLog(cat, fmt, ...) SCIFileLogWrite((cat), [NSString stringWithFormat:(fmt), ##__VA_ARGS__])

#else // SCI_FILELOG == 0 — compiled out entirely.

NS_INLINE void SCIFileLogWrite(NSString * _Nullable category, NSString *message) { (void)category; (void)message; }
NS_INLINE NSString * _Nullable SCIFileLogPath(void) { return nil; }
NS_INLINE NSURL * _Nullable SCIFileLogURL(void) { return nil; }
NS_INLINE void SCIFileLogClear(void) {}
NS_INLINE NSString * _Nullable SCIFileLogExportToDocuments(void) { return nil; }
NS_INLINE void SCIFileLogSetEnabled(BOOL enabled) { (void)enabled; }
NS_INLINE BOOL SCIFileLogIsEnabled(void) { return NO; }

#define SCIFLog(cat, fmt, ...) do {} while (0)

#endif

NS_ASSUME_NONNULL_END
