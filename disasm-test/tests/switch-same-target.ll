
define i32 @f(i32 %x) {
  switch i32 %x, label %default [
    i32 1, label %isOne
    i32 2, label %isOne
  ]

default:
  ret i32 0

isOne:
  ret i32 1
}
