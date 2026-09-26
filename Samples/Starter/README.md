# Starter Project

`hamii.json` と各 entity directory は Current Canonical Format v1 の sample です。`Design` Page は `Welcome` Screen を iPhone 17 / iOS 26.5 と Mac / macOS 26 の SwiftUI AppSurface で参照します。Screen root は Stack、Text、Button Layer を持ち、Spacing Token の alias を参照します。両 Target は `layout.stack`、`component.text`、`component.button`、`token.spacing` capability を宣言しています。macOS editor では Native Preview に切り替えられます。

Repository root から検証できます。

```bash
~/.swiftly/bin/swift run hamii -- --project Samples/Starter --json validate
~/.swiftly/bin/swift run hamii -- --project Samples/Starter --json inspect
```

新規 project として編集する場合は directory を別の Git repository にコピーして使用してください。CLI または hamii-studio から semantic intent で変更します。
