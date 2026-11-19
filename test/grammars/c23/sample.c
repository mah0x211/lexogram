#include <stddef.h>
typedef int T;
static_assert(sizeof(int) >= 2, "int");
static_assert(sizeof(long) >= 4);
_Static_assert(1, "old spelling");
constexpr int limit = 1'000'000;
thread_local int counter;
alignas(16) char buffer[64];
alignas(double) char aligned;
bool flag = true;
_Bool old = false;
int *p = nullptr;
unsigned long long big = 0b1010'1010 + 0x1'FF + 07'7 + 10uLL;
_BitInt(12) small = 10wb;
unsigned _BitInt(12) usmall = 10uwb;
double d = 1'000.5e1'0 + 0x1.8p1;
typeof(limit) copy = 2;
typeof_unqual(const int) plain = 3;
typeof(int *) ip = nullptr;
enum E : unsigned char { A, B = 2, };
enum F : T { C };
enum E2 : long;
struct S { int a; struct { int x, y; }; unsigned b : 3; };
int empty[2] = {};
char c8 = u8'a';
void variadic(...);
int f(int n) {
    int a = alignof(int) + _Alignof(T);
    struct S s = {};
    auto x = 1;
    typeof(s.a) y = (typeof(y)){ 0 };
    switch (n) {
    case 1:
        int z = 2;
        a += z;
        break;
    default:
    }
    if (n) {
        a++;
    end:
    }
    return a + x + y;
}
