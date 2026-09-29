<div align="center">
    <img width="160" height="160" src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png">
    <h1>pixes（个人分支）</h1>
    <p>基于 <a href="https://github.com/wgh136/pixes">pixes</a> 的 Pixiv 第三方客户端，自动跟进上游更新。</p>
</div>

## 和上游的区别

- **自动播放**：在探索、收藏、关注页点右上角的播放按钮，全屏逐张浏览，上下滑切换作品，左右滑翻多图。播放时操作层自动隐藏；单击暂停，双击点赞，长按调速度。
- **小说自动滚动**：阅读时可开启，速度可调，滚动期间屏幕保持常亮。
- **切换不刷新**：在侧边栏各页面或页内的分类之间来回切换时，内容和滚动位置都会保留，不会重新加载。
- **点赞、收藏、关注即时生效**：点击后立刻更新，请求在后台发送，失败时恢复原状并提示。
- 若干界面修复：手机上顶部栏遮挡页面、窄屏标题溢出、小说推荐翻页重复、侧边栏图标调整等。

其余功能和上游一致，使用说明请看[上游项目](https://github.com/wgh136/pixes)。

## 下载

到 [Releases](../../releases) 下载：

- Android：一般手机选 `pixes-<版本>-arm64-v8a.apk`
- iOS：`pixes-custom-ios-unsigned.ipa`，未签名，需要自己签名安装

上游每次更新后会自动合并并重新构建，版本号形如 `1.2.3-fork.7`。

## 许可

与上游相同，采用 [MIT](LICENSE) 许可。
