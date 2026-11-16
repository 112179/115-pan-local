import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

/// 播放页横竖屏控制
///
/// 之前的问题：
/// 1. 只改 static 变量不刷新 VC，UIKit 不会重新查询方向 → 转屏按钮点了没反应
/// 2. 只对 window.rootViewController 调用 setNeedsUpdate → 全屏播放页是 present 出来的，
///    真正决定方向的是最上层 VC，刷错了对象
/// 3. 在播放页 dismiss 的同时强转竖屏 → 退出动画期间布局错乱
enum PlayerOrientation {
    static func allowAll() {
        apply(.allButUpsideDown, force: false)
    }

    static func lockPortrait() {
        apply(.portrait, force: true)
    }

    static func toggle() {
        guard let scene = currentScene() else { return }
        let target: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape
            ? .portrait
            : .landscapeRight
        apply(target, force: true)
    }

    /// 进入播放页时，让界面跟上设备物理方向（手机已经横着拿的情况）
    static func matchDevice() {
        guard let scene = currentScene() else { return }
        let device = UIDevice.current.orientation
        let interface = scene.interfaceOrientation

        if device.isLandscape, !interface.isLandscape {
            let mask: UIInterfaceOrientationMask = device == .landscapeLeft ? .landscapeLeft : .landscapeRight
            apply(mask, force: true)
        } else if device.isPortrait, interface.isLandscape {
            apply(.portrait, force: true)
        }
    }

    static var isLandscape: Bool {
        currentScene()?.interfaceOrientation.isLandscape ?? false
    }

    static func apply(_ mask: UIInterfaceOrientationMask, force: Bool) {
        AppDelegate.orientationLock = mask
        guard let scene = currentScene() else { return }

        // 先让整条 VC 链重新查询 supportedInterfaceOrientations
        refreshControllers(in: scene)

        guard force else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("orientation update failed: \(error)")
        }
        // requestGeometryUpdate 之后 iOS 会重建布局，再刷新一次避免残留
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            refreshControllers(in: scene)
        }
    }

    private static func refreshControllers(in scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                if let nav = current as? UINavigationController,
                   let top = nav.topViewController {
                    top.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
                if let tab = current as? UITabBarController,
                   let selected = tab.selectedViewController {
                    selected.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
                controller = current.presentedViewController
            }
        }
    }

    private static func currentScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
