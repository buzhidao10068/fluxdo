#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// 注册窗口和查找授权回调接收实例必须共用 fork 专属标识。
inline constexpr wchar_t kWindowClassName[] =
    L"com.buzhidao10068.fluxdo.RunnerWindow";

#endif  // RUNNER_APP_IDENTITY_H_
