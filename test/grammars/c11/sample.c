#include <stddef.h>
typedef int T;
_Static_assert(sizeof(int) >= 2, "int " "is too small");
static _Thread_local int counter;
_Alignas(16) char buffer[64];
_Alignas(double) char aligned;
_Atomic int ai;
_Atomic(long) al;
_Atomic(T) *apt;
int *_Atomic pa;
const _Atomic T cat;
struct S {
    int kind;
    union { int i; float f; };
    struct { int x, y; };
    _Alignas(8) char tag;
    _Static_assert(1, "members too");
};
_Noreturn void fail(void);
inline _Noreturn static void stop(void) { for (;;) ; }
void f(_Atomic(int) *p, const _Atomic int q);
const char *u8s = u8"utf-8";
const unsigned short *u16s = u"utf-16";
const unsigned int *u32s = U"utf-32";
unsigned short c16 = u'a';
unsigned int c32 = U'b';
#define type_name(x) _Generic((x), int: "int", T *: "pointer", default: "other")
int main(void) {
    struct S s;
    _Static_assert(_Alignof(struct S) >= 1, "alignment");
    size_t a = _Alignof(double) + _Alignof(T);
    const char *n = _Generic(a, size_t: "size_t", default: "other");
    s.i = 1;
    s.x = s.y = 2;
    return (int)a + (int)sizeof(n) + s.i;
}
