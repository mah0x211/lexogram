#include <stddef.h>
%: define DIGRAPH 1
typedef int T;
typedef struct S { int a; unsigned b : 3; int : 0; struct S *next; } S;
typedef union U { int i; float f; } U;
enum E { A, B = 2, C, };
enum E2 { X };
static const char *names[] = { "a", "b" L"" , };
int arr[3] = { [0] = 1, [2] = 3 };
S s1 = { .a = 1, .b = 2 };
struct P { int x, y; } p1 = { 1, 2 }, *pp = &p1;
extern int f1(void);
int f2(int, char *, ...);
int (*fp)(int);
int (*fpa[2])(void);
char *(*(*x)[3])(void);
T (*tf)(T);
void k(T a, T *b, const T c, int d[static 3], int e[const 2], int g[*]);
void l(int n, int m[n][n]);
inline static int f3(int a) { return a; }
int f4(a, b) int a; char *b; { return a + *b; }
int (f5)(int a) { return a; }
T f6(T t) { return t; }
S *f7(S *s) { return s->next; }
static T *f8(void) { return 0; }
long long ll = 10LL + 0x1fULL + 017u + 1lu;
double d1 = 1.5e-3 + .5 + 1. + 0x1.8p3 + 1e10f + 2.0L;
char c1 = 'a', c2 = '\n', c3 = '\x41', c4 = '\101', c5 = '\'';
_Bool bb = 1;
_Complex double cd;
int main(void) {
    int i, j = 0, *k = &j, n[4] <: 2 :> = <% 0 %>;
    T t = 1;
    T *tp = &t;
    S st;
    unsigned long ul = sizeof(int) + sizeof i + sizeof(T) + sizeof (st) + sizeof *k;
    for (int q = 0; q < 3; q++) { j += q; }
    for (i = 0, j = 1; i < 10; i++, j--) continue;
    for (;;) break;
    while (i--) ;
    do { i++; } while (i < 5);
    if (i) j = 1; else if (j) i = 2; else { i = 3; }
    if (i) if (j) i = 0; else j = 0;
    switch (i) { case 1: case 2 + 1: j = 1; break; default: j = 2; }
    goto end;
end:
    i = j > 0 ? j : -j;
    i = (int)ul + (T)i + (unsigned char)c1;
    i = ((int)(long)ul);
    tp = (T *)tp;
    st = (S){ .a = 1 };
    i = (S){ 1, 2 }.a;
    i = (int)ul + (T)i + (unsigned char)c1 + *(T *)tp;
    i <<= 2; i >>= 1; i &= 3; i |= 4; i ^= 5; i %= 7; i *= 2; i /= 2; i += 1; i -= 1;
    i = !i && ~j || i != j;
    i = (i, j);
    k = &n[2];
    *k = *k * 2;
    i = -*k + +j - - j;
    st.a++; ++st.a; tp[0]--; --tp[0];
    f1();
    (void)f2(1, "x", 2, 3);
    (*fp)(1);
    fp(2);
    i = f3(i) + f6(t);
    { int inner; inner = 1; i += inner; }
    ;
    return i ? 0 : 1;
}
