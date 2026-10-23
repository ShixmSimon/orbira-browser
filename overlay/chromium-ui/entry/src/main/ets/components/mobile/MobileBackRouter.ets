/*
 * The entry page (AuraShell) receives the system back gesture through
 * onBackPress, but the browser chrome state -- the tab menu, a full-screen
 * shell page, address editing, page history -- lives inside
 * MobileBrowserOverlay. The overlay registers a handler here when it appears;
 * the page asks it before letting the gesture fall through to "exit the app".
 */
export class MobileBackRouter {
  static handler: (() => boolean) | undefined = undefined;
}
