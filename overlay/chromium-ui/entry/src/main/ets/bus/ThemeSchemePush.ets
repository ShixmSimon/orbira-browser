// 全局单例：设置面板切完外观后，把新配色直接推给 EntryAbility 的钩子。
//
// 为什么需要它：引擎只在"启动配置被重新应用"那一刻换色，而配置的重新下发
// 挂在 onConfigurationUpdate 上 —— 系统 对 setColorMode 的这个回调不保证立刻、
// 甚至不保证必然到达（真机上壳已变色而引擎纹丝不动）。与面板页化后命令走
// BrowserCommandBus 同一套模式：面板与 ability 之间没有直接引用，用全局单例
// 把"用户选了什么"递回给持有路由状态的 ability，由它重序列化启动配置并顶起
// revision（与折叠/旋转同一条已验证的下发路径）。
type SchemeHandler = (scheme: 'light' | 'dark') => void;

class ThemeSchemePushImpl {
  private handler: SchemeHandler | null = null;

  setHandler(handler: SchemeHandler): void {
    this.handler = handler;
  }

  // 箭头函数属性：构造时即绑定 this，可直接作为回调传递。
  dispatch = (scheme: 'light' | 'dark'): void => {
    if (this.handler) {
      this.handler(scheme);
    } else {
      console.warn('ThemeSchemePush: no handler registered, dropped scheme: ' + scheme);
    }
  };
}

export const ThemeSchemePush: ThemeSchemePushImpl = new ThemeSchemePushImpl();
