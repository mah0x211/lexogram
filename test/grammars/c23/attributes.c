[[deprecated]] int a;
[[nodiscard("why"), maybe_unused]] int f(void);
int [[vendor::tag(8)]] b;
int c [[maybe_unused]], d [[deprecated]] = 1;
int arr[2] [[vendor::tag]];
int g(int x) [[unsequenced]];
int * [[clang::annotate_type("p")]] p;
struct [[deprecated]] S { [[maybe_unused]] int m [[deprecated]]; int : 3; };
union [[deprecated]] U { int u; };
enum [[deprecated]] E { A [[deprecated]], B [[deprecated]] = 2 };
void h([[maybe_unused]] int y, int z [[maybe_unused]], int [[vendor::tag]]);
[[nodiscard]] static int k(void) { return 0; }
int (fp [[maybe_unused]])(int);
int (*q)([[maybe_unused]] int);
[[]];
[[vendor::thing(1 + (2, [3]), {4}, if, int)]];
void body(int n) {
    [[maybe_unused]] int local = 0;
    switch (n) {
    case 1:
        [[fallthrough]];
    case 2:
        break;
    }
    [[likely]] if (n) {}
    [[maybe_unused]] l: n++;
    [[vendor::tag]] return;
}
int t = sizeof(int [[vendor::tag]]);
