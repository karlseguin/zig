extern fn puts(s: [*:0]const u8) c_int;

pub fn main() void {
    _ = puts("hello world!");
}

// run
// backend=llvm
// target=x86_64-linux
//
// hello world!
//
