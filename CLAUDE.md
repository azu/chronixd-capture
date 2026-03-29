# CLAUDE.md

## Build

```sh
swift build --disable-sandbox
```

Release build:

```sh
swift build --disable-sandbox -c release
```

## chronixd-capture.app

`.app` バンドルの生成:

```sh
./scripts/bundle-chronixd-capture.sh
open .build/chronixd-capture.app
```
