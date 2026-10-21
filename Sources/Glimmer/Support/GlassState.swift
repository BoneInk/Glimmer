import SwiftUI

/// `@GlassState` — 与 `@State` 等价的属性包装器别名。
///
/// 背景：本机只安装了 CommandLineTools，缺少 SwiftUI 的宏插件（`SwiftUIMacros`），
/// 而 macOS 27 SDK 把 `State` 声明为宏（`public macro State()`），因此直接写 `@State`
/// 会报「external macro implementation type 'SwiftUIMacros.StateMacro' could not be found」。
///
/// 通过类型别名指向 *已存在* 的公开属性包装器结构体 `SwiftUI.State`，可以让编译器
/// 在属性位置解析到结构体而不是宏，从而使用同一份系统实现，无需修改 SDK 或系统环境。
///
/// 用法与 `@State` 完全一致（含 `$` 投影值）。
typealias GlassState<Value> = SwiftUI.State<Value>
