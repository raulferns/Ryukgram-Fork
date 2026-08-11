// SCIMobileConfigEmployeeGate.x
// =====================================================================
// Força a determinação REAL de employee/test-user/dogfooding — a camada
// UPSTREAM que decide o acesso a Internal Settings / Dogfooding.
// =====================================================================
// Validado no binário (Instagram + FBSharedFramework, UUID 4C4C4424/4C4C446A):
//   O consumidor do descriptor _ig_is_employee_or_test_user faz:
//     ldr x8,[slot 0x10E0394E8]  ; x8 = descriptor
//     ldr x2,[x8]                ; x2 = descriptor->field0 (config do gate)
//     objc_msgSend(receiver, @selector(getBool:), x2)
//   ou seja: [<MobileConfigManager> getBool: field0]. Seletor confirmado
//   = "getBool:" (selref 0x10F85D360). Isso é a camada de MobileConfig da
//   SESSÃO — independente dos getters ObjC -isEmployee (downstream) que o
//   SCIEmployeeConsumers força. Por isso forçar isEmployee nunca mudou o acesso.
//
//   getBool: é implementado por classes ObjC do FBSharedFramework
//   (IG/FBMobileConfigUserSessionContextManager, ...ContextManager) -> hookável
//   por MSHookMessageEx (swizzle em runtime, SIDELOAD-SAFE: sem patch em __TEXT,
//   sem fishhook de C, nada que crashe code-signing).
//
// Direcionamento (seção 11 da análise): força YES SÓ quando o argumento do
// getBool: é o field0 (ou o próprio descriptor) de um dos gates de identidade:
// ig_is_employee, ig_is_employee_or_test_user, ig_dogfooding_assistant.
// Todo o resto cai em %orig -> não força gates alheios -> não crasha como o
// "return true cego" do EasyGating.

#import <substrate.h>
#import <objc/runtime.h>
#import "../../Utils.h"
#import "../Dogfooding/SCIInternalGatePrefs.h"
#import "../../SCIFileLog.h"
#import <dlfcn.h>

static const char *kEmpSyms[] = {
	"ig_is_employee",
	"ig_is_employee_or_test_user",
	"ig_dogfooding_assistant",
};
enum { kEmpN = (int)(sizeof(kEmpSyms) / sizeof(kEmpSyms[0])) };

static void *sDesc[kEmpN];
static void *sField0[kEmpN];
static BOOL  sResolved[kEmpN];
static BOOL  sActive = NO;
static volatile int sHitMask = 0;

static inline int sciMatchEmp(void *p) {
	if (!p) return -1;
	for (int i = 0; i < kEmpN; i++)
		if (sResolved[i] && (p == sDesc[i] || p == sField0[i])) return i;
	return -1;
}

static inline void sciEmpLog(int m, id self) {
	if (!SCIFileLogIsEnabled()) return;
	if (sHitMask & (1 << m)) return;
	sHitMask |= (1 << m);
	SCIFLog(@"SCIEmpGate", @"forced getBool:%s -> YES on %s", kEmpSyms[m], object_getClassName(self));
}

#define GB_HOOK(TAG) \
	static BOOL (*orig_##TAG)(id, SEL, void *) = NULL; \
	static BOOL repl_##TAG(id self, SEL _cmd, void *cfg) { \
		if (sActive) { int m = sciMatchEmp(cfg); if (m >= 0) { sciEmpLog(m, self); return YES; } } \
		return orig_##TAG ? orig_##TAG(self, _cmd, cfg) : NO; \
	}

GB_HOOK(a)
GB_HOOK(b)
GB_HOOK(c)
GB_HOOK(d)

static void sciHookGetBool(const char *clsName, IMP repl, IMP *orig) {
	Class c = objc_getClass(clsName);
	if (!c) return;
	SEL sel = @selector(getBool:);
	if (!class_getInstanceMethod(c, sel)) return;
	@try { MSHookMessageEx(c, sel, repl, orig); } @catch (__unused NSException *e) {}
}

%ctor {
	@autoreleasepool {
		sActive = [SCIInternalGatePrefs employeeInternalMasterEnabled]
		       || [SCIUtils getBoolPref:@"sci_force_mc_session_employee_gate"];
		if (!sActive) return;

		for (int i = 0; i < kEmpN; i++) {
			void *d = dlsym(RTLD_DEFAULT, kEmpSyms[i]);
			if (!d) continue;
			sDesc[i] = d; sField0[i] = *(void **)d; sResolved[i] = YES;
		}

		sciHookGetBool("IGMobileConfigUserSessionContextManager", (IMP)repl_a, (IMP *)&orig_a);
		sciHookGetBool("FBMobileConfigUserSessionContextManager", (IMP)repl_b, (IMP *)&orig_b);
		sciHookGetBool("IGMobileConfigContextManager",            (IMP)repl_c, (IMP *)&orig_c);
		sciHookGetBool("FBMobileConfigContextManager",            (IMP)repl_d, (IMP *)&orig_d);

		if (SCIFileLogIsEnabled())
			SCIFLog(@"SCIEmpGate", @"installed active=%d resolved=%d/%d",
			        sActive, sResolved[0] + sResolved[1] + sResolved[2], kEmpN);
	}
}
