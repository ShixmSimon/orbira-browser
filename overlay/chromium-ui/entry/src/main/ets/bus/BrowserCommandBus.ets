// 全局命令总线：把面板（现在可能是独立路由页）发回浏览器壳的指令桥接起来。
// 浏览器壳在启动时通过 setHandler 注册自己的 issueCommand；面板改为调用
// BrowserCommandBus.dispatch，这样无论面板是 overlay 子组件还是独立 @Entry 路由页，
// 同一调用都有效。
import { BrowserCommandPayload } from 'engine';

type CommandHandler = (command: BrowserCommandPayload) => void;

class BrowserCommandBusImpl {
  private handler: CommandHandler | null = null;

  setHandler(handler: CommandHandler): void {
    this.handler = handler;
  }

  // 箭头函数属性：构造时即绑定 this，可作为值直接传给面板 onCommand 属性。
  dispatch = (command: BrowserCommandPayload): void => {
    if (this.handler) {
      this.handler(command);
    } else {
      console.warn('BrowserCommandBus: no handler registered, dropped command: ' +
        JSON.stringify(command));
    }
  };
}

export const BrowserCommandBus: BrowserCommandBusImpl = new BrowserCommandBusImpl();
