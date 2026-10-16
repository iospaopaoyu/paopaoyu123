#import <objc/runtime.h>
#import <string.h>
#import "WCHeaders.h"
#import "WCPluginsHeader.h"
#import "TouSongController.h"
#import "TouSongManager.h"
#import "KaMiManagerController.h"

%config(generator=internal);

// 插件元信息（与主题兑换插件完全隔离）
static NSString *TouSongBiaoti = @"主题投送";
static NSString *TouSongVersion = @"1.0";

// 本地读取本插件显示名（读自己的 ZhuTiTouSongName.plist），避免与主题兑换插件共用 WCPluginsMgr 同名方法互相覆盖
static NSString *touSongPluginDisplayName(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"Preferences"];
    NSString *plistPath = [dir stringByAppendingPathComponent:@"ZhuTiTouSongName.plist"];
    NSString *custom = [[NSDictionary dictionaryWithContentsOfFile:plistPath] objectForKey:@"ChaJianMingZi"];
    return (custom && custom.length > 0) ? custom : TouSongBiaoti;
}

// 获取顶层视图控制器
static UIViewController *TopViewController(void) {
    UIViewController *rootViewController = nil;

    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindow *window = scene.windows.firstObject;
                if (window) {
                    rootViewController = window.rootViewController;
                    break;
                }
            }
        }
    } else {
        rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    }

    if (!rootViewController) {
        return nil;
    }

    while (rootViewController.presentedViewController) {
        rootViewController = rootViewController.presentedViewController;
    }

    return rootViewController;
}

// 从 XML 内容中解析指定标签的值（兼容 CDATA），用于群聊消息真实发送者提取
static NSString *parsedTagFromXMLString(NSString *xml, NSString *tag) {
    if (!xml || xml.length == 0 || !tag || tag.length == 0) return nil;
    @try {
        NSString *pattern = [NSString stringWithFormat:@"<%@[^>]*>(.*?)</%@>", tag, tag];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                            options:NSRegularExpressionDotMatchesLineSeparators
                                                                              error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
        if (match && match.numberOfRanges >= 2 && match.range.length > 0) {
            NSString *value = [xml substringWithRange:[match rangeAtIndex:1]];
            // 剥离 CDATA 包裹
            if ([value hasPrefix:@"<![CDATA["] && [value hasSuffix:@"]]>"]) {
                value = [value substringWithRange:NSMakeRange(9, value.length - 9 - 3)];
            }
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (value.length > 0) return value;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 获取群聊消息的真实发送者wxid（用于双击消息时确定投送对象）
static NSString *realSenderWXIDFromWrap(CMessageWrap *wrap) {
    // 1. 直接字段候选（不同微信版本字段名可能不同）
    @try {
        NSArray *candidateKeys = @[@"m_nsRealChatUsr", @"m_nsRealChatRoomID", @"m_nsGroupFromUsr", @"m_nsChatRoomFromUsr", @"m_nsSourceUsr"];
        for (NSString *key in candidateKeys) {
            NSString *value = [wrap valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && value.length > 0) {
                return value;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"获取群聊真实发送者失败: %@", exception.reason);
    }

    // 2. 新版群聊 content 为 XML，解析 <fromusername>
    NSString *content = wrap.m_nsContent;
    if (content && content.length > 0) {
        if ([content hasPrefix:@"<"]) {
            NSString *from = parsedTagFromXMLString(content, @"fromusername");
            if (from) return from;
        }

        // 3. 旧版微信群消息 content 前缀格式: "发送者wxid:\n内容"
        NSRange colonRange = [content rangeOfString:@":\n"];
        if (colonRange.location != NSNotFound && colonRange.location >= 4 && colonRange.location <= 25) {
            NSString *prefix = [content substringToIndex:colonRange.location];
            NSCharacterSet *invalidSet = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
            if (prefix.length > 0 && [prefix rangeOfCharacterFromSet:invalidSet].location == NSNotFound) {
                return prefix;
            }
        }
    }
    return nil;
}

// 从消息单元格中提取 CMessageWrap（通过 viewModel，运行时反射避免链接期强引用）
static CMessageWrap *messageWrapFromCell(UIView *cell) {
    @try {
        Class wrapClass = objc_getClass("CMessageWrap");
        id vm = [cell valueForKey:@"m_viewModel"];
        if (!vm) vm = [cell valueForKey:@"viewModel"];
        if (!vm) vm = [cell valueForKey:@"_viewModel"];
        if (vm) {
            // 优先走 getter
            SEL msgWrapSel = NSSelectorFromString(@"messageWrap");
            if ([vm respondsToSelector:msgWrapSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id wrap = [vm performSelector:msgWrapSel];
                #pragma clang diagnostic pop
                if (wrapClass && [wrap isKindOfClass:wrapClass]) return (CMessageWrap *)wrap;
            }
            id wrap = [vm valueForKey:@"messageWrap"];
            if (wrapClass && [wrap isKindOfClass:wrapClass]) return (CMessageWrap *)wrap;
            wrap = [vm valueForKey:@"m_messageWrap"];
            if (wrapClass && [wrap isKindOfClass:wrapClass]) return (CMessageWrap *)wrap;
        }
        id direct = [cell valueForKey:@"m_messageWrap"];
        if (wrapClass && [direct isKindOfClass:wrapClass]) return (CMessageWrap *)direct;
        direct = [cell valueForKey:@"messageWrap"];
        if (wrapClass && [direct isKindOfClass:wrapClass]) return (CMessageWrap *)direct;
    } @catch (NSException *e) {}
    return nil;
}

// 插件管理接入（从主题兑换源码搬移，仅保留投送入口）
%group chajianguanlijieru
%hook MinimizeViewController

- (void)viewDidLoad {
    %orig;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
            @try {
                Class wcPluginsMgr = objc_getClass("WCPluginsMgr");
                id instance = [wcPluginsMgr performSelector:@selector(sharedInstance)];
                if (instance) {
                    NSString *pluginName = touSongPluginDisplayName();

                    if ([instance respondsToSelector:@selector(registerControllerWithTitle:version:controller:)]) {
                        // 投送入口 = 卡密管理面板
                        [instance registerControllerWithTitle:pluginName
                                                     version:TouSongVersion
                                                  controller:@"KaMiManagerController"];
                    }
                }
            } @catch (NSException *exception) {}
    });
}

%end
%end

// 长按消息菜单投送入口
static NSDictionary *g_pendingTargetInfo = nil; // 长按消息时解析出的投送目标 {targetWXID, targetNickName, targetChatID, chatContext}
static char kTouSongOrigDelegateKey;   // 旧版代理链：缓存官方原始代理
static char kTouSongFallbackInfoKey;   // 旧版代理链：缓存投送目标
static char kTouSongMenuInfoKey;       // MMMenuController：缓存点击「投送」时弹出的目标

// 从长按的消息单元格解析出投送目标（对方wxid + 会话上下文）
static NSDictionary *resolveTouSongTargetFromCell(WCMessageCell *cell) {
    CMessageWrap *wrap = messageWrapFromCell(cell);
    if (!wrap) return nil;

    NSString *fromUsr = wrap.m_nsFromUsr;
    if (!fromUsr || fromUsr.length == 0) return nil;

    BOOL msgFromGroup = [fromUsr hasSuffix:@"@chatroom"];
    NSString *targetWXID = msgFromGroup ? realSenderWXIDFromWrap(wrap) : fromUsr;
    if (!targetWXID || targetWXID.length == 0) return nil;

    // 跳过自己发送的消息，确保是对方
    NSString *selfWXID = nil;
    Class mmContextClass = objc_getClass("MMContext");
    if (mmContextClass && [mmContextClass respondsToSelector:@selector(currentUserName)]) {
        selfWXID = [mmContextClass currentUserName];
    }
    if (selfWXID && [targetWXID isEqualToString:selfWXID]) return nil;

    // 沿响应链查找当前聊天控制器，获取会话ID与会话名
    UIResponder *next = cell.nextResponder;
    UIViewController *chatVC = nil;
    while (next) {
        if ([next isKindOfClass:NSClassFromString(@"BaseMsgContentViewController")]) {
            chatVC = (UIViewController *)next;
            break;
        }
        next = next.nextResponder;
    }

    NSString *chatID = nil;
    NSString *chatName = nil;
    if (chatVC && [chatVC respondsToSelector:@selector(GetContact)]) {
        id contact = [chatVC performSelector:@selector(GetContact)];
        if (contact) {
            @try {
                chatID = [contact valueForKey:@"m_nsUsrName"];
                chatName = [contact valueForKey:@"m_nsNickName"];
            } @catch (NSException *e) {}
        }
    }
    if (!chatID || chatID.length == 0) return nil;

    BOOL chatIsGroup = [chatID hasSuffix:@"@chatroom"];
    NSString *displayChatName = (chatName && chatName.length > 0) ? chatName : chatID;
    // 私聊用会话昵称（来自 GetContact，安全）；群聊为避免在主线程反射私有类闪退，暂用 wxid 回退
    NSString *targetNick = chatIsGroup ? targetWXID : displayChatName;

    NSDictionary *chatContext = @{@"isGroup": @(chatIsGroup), @"chatName": displayChatName, @"senderName": targetNick};

    return @{@"targetWXID": targetWXID,
             @"targetNickName": targetNick,
             @"targetChatID": chatID,
             @"chatContext": chatContext};
}

// 根据已解析的目标信息弹出投送面板
static void presentTouSongFromTargetInfo(NSDictionary *info) {
    if (!info) return;
    NSString *wxid = info[@"targetWXID"];
    NSString *nick = info[@"targetNickName"];
    NSString *chatID = info[@"targetChatID"];
    NSDictionary *ctx = info[@"chatContext"];
    if (!wxid || wxid.length == 0) return;
    if (!nick || nick.length == 0) nick = wxid;

    TouSongController *vc = [[TouSongController alloc] init];
    vc.targetWXID = wxid;
    vc.targetNickName = nick;
    vc.targetChatID = chatID;
    vc.chatContext = ctx;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    UIViewController *top = TopViewController();
    if (top) {
        [top presentViewController:nav animated:YES completion:nil];
    }
}

// 从收/发消息 wrap 解析会话上下文（群聊/私聊、会话ID、真实发送者ID）
// 注意：此处只做纯字符串/属性读取，不做微信私有类昵称反查（该反查涉及数据库，主线程会崩溃）
static NSDictionary *chatContextFromWrap(CMessageWrap *wrap) {
    NSString *fromUsr = wrap.m_nsFromUsr;
    BOOL isGroup = [fromUsr hasSuffix:@"@chatroom"];
    NSString *senderWXID = isGroup ? (realSenderWXIDFromWrap(wrap) ?: fromUsr) : fromUsr;
    return @{@"isGroup": @(isGroup), @"chatName": fromUsr, @"senderName": senderWXID};
}

// 指令触发：直接按 wxid + 会话 + 说明 弹出投送面板（主线程调用）
static void presentTouSongFromWXID(NSString *wxid, NSString *chatID, NSDictionary *chatContext, NSString *note) {
    if (!wxid || wxid.length == 0) return;

    TouSongController *vc = [[TouSongController alloc] init];
    vc.targetWXID = wxid;
    vc.targetNickName = wxid;
    vc.targetChatID = chatID;
    vc.chatContext = chatContext;
    vc.note = note;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    UIViewController *top = TopViewController();
    if (top) {
        [top presentViewController:nav animated:YES completion:nil];
    }
}

// 指令去重（AddMsg/AsyncOnAddMsg 对同一条消息可能双路径触发，避免弹两次面板）
static NSString *g_lastCommandKey = nil;
static NSTimeInterval g_lastCommandTime = 0;

// 解析并处理指令消息：#主题投送 <wxid> [说明…]
// 全程 @try 兜底，绝不因指令识别失败导致微信发消息闪退
static void handleTouSongCommand(CMessageWrap *wrap) {
    @try {
        if (!wrap) return;
        NSString *content = wrap.m_nsContent;
        if (!content || content.length == 0) return;

        NSString *command = [TouSongManager sharedInstance].triggerCommand;
        NSString *trimmed = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *prefix = [command stringByAppendingString:@" "];
        if (![trimmed hasPrefix:prefix]) return;

        NSString *rest = [[trimmed substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *rawTokens = [rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableArray *words = [NSMutableArray array];
        for (NSString *tk in rawTokens) {
            if (tk.length > 0) [words addObject:tk];
        }
        NSString *wxid = words.count > 0 ? words[0] : nil;
        NSString *note = @"";
        if (words.count > 1) {
            note = [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "];
        }
        if (!wxid || wxid.length == 0) return;

        NSString *chatID = wrap.m_nsFromUsr ?: @"";

        // 线程安全去重：2 秒内同一条指令（内容+会话相同）只处理一次
        NSString *key = [NSString stringWithFormat:@"%@|%@", trimmed, chatID];
        @synchronized([TouSongManager sharedInstance]) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if ([key isEqualToString:g_lastCommandKey] && (now - g_lastCommandTime) < 2.0) {
                return;
            }
            g_lastCommandKey = key;
            g_lastCommandTime = now;
        }

        // 会话上下文（仅在消息线程做纯属性读取，不反射私有类）
        NSDictionary *ctx = chatContextFromWrap(wrap);

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NSLog(@"[ZhuTiTouSong] 识别投送指令，目标 wxid: %@，说明: %@", wxid, note);
                presentTouSongFromWXID(wxid, chatID, ctx, note);
            } @catch (NSException *e) {
                NSLog(@"[ZhuTiTouSong] 弹面板异常: %@", e.reason);
            }
        });
    } @catch (NSException *e) {
        NSLog(@"[ZhuTiTouSong] 指令处理异常: %@", e.reason);
    }
}

%group zhilingtousong

%hook CMessageMgr

// 自己发送指令（聊天窗口输入 #主题投送 wxid …）
- (void)AddMsg:(NSString *)msg MsgWrap:(CMessageWrap *)wrap {
    %orig;
    handleTouSongCommand(wrap);
}

// 接收指令（他人发送，兼容不同微信版本消息路径）
- (void)AsyncOnAddMsg:(NSString *)msg MsgWrap:(CMessageWrap *)wrap {
    %orig;
    handleTouSongCommand(wrap);
}

%end
%end

%group changanyemenu

// 长按消息时记录投送目标（在 %orig 之前执行，确保菜单弹出时目标已就绪）
static void cacheTouSongTargetFromCell(WCMessageCell *cell) {
    if (!cell) return;
    NSDictionary *info = resolveTouSongTargetFromCell(cell);
    if (info) {
        g_pendingTargetInfo = info;
        NSLog(@"[ZhuTiTouSong] 长按命中投送对象: %@ (%@)", info[@"targetNickName"], info[@"targetWXID"]);
    } else {
        NSLog(@"[ZhuTiTouSong] 长按消息但未解析到投送对象");
    }
}

%hook WCMessageCell

- (void)handleLongPress:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)onLongPress:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)longPressed:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)handleLongPressGesture:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)onLongPressGesture:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)handleMenuGesture:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

- (void)longPressGestureRecognized:(id)gesture {
    cacheTouSongTargetFromCell(self);
    %orig;
}

%end

// 在长按菜单（WCActionSheet 旧版竖排 / WCMenuView 新版网格）弹出时追加「投送」入口
static void injectTouSongIntoMenu(id sheet) {
    if (!sheet) return;
    NSDictionary *info = g_pendingTargetInfo;
    if (!info) return;
    g_pendingTargetInfo = nil; // 一次性消费，避免污染其它弹窗

    // 优先 block 回调：微信组件多复用 addButtonWithTitle:eventAction:
    if ([sheet respondsToSelector:@selector(addButtonWithTitle:eventAction:)]) {
        [(WCActionSheet *)sheet addButtonWithTitle:@"投送" eventAction:^{
            presentTouSongFromTargetInfo(info);
        }];
        NSLog(@"[ZhuTiTouSong] 投送入口注入成功(block,%@): %@", NSStringFromClass([sheet class]), info[@"targetNickName"]);
        return;
    }

    // 无 block：追加到末尾 + 接管代理链，官方按钮 index 不受影响
    if (![sheet respondsToSelector:@selector(addButtonWithTitle:)]) {
        NSLog(@"[ZhuTiTouSong] 菜单类 %@ 无可用添加方法，注入失败", NSStringFromClass([sheet class]));
        return;
    }
    @try {
        id origDelegate = [(WCActionSheet *)sheet m_delegate];
        objc_setAssociatedObject(sheet, &kTouSongOrigDelegateKey, origDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, &kTouSongFallbackInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sheet addButtonWithTitle:@"投送"];
        [(WCActionSheet *)sheet setM_delegate:(id<WCActionSheetDelegate>)sheet]; // 自己接管点击，再转发非投送按钮
        NSLog(@"[ZhuTiTouSong] 投送入口注入成功(代理链,%@): %@", NSStringFromClass([sheet class]), info[@"targetNickName"]);
    } @catch (NSException *e) {
        NSLog(@"[ZhuTiTouSong] 代理链注入异常(%@): %@", NSStringFromClass([sheet class]), e.reason);
    }
}

// 代理链点击回调（仅当 m_delegate 被替换为 self 时触发）
static void handleTouSongItemClick(id sheet, long long index) {
    NSDictionary *info = objc_getAssociatedObject(sheet, &kTouSongFallbackInfoKey);
    id origDelegate = objc_getAssociatedObject(sheet, &kTouSongOrigDelegateKey);
    NSArray *buttons = nil;
    @try { buttons = [(WCActionSheet *)sheet buttonTitleList]; } @catch (NSException *e) {}
    long long ourIndex = (buttons && [buttons isKindOfClass:[NSArray class]] && buttons.count > 0) ? (long long)(buttons.count - 1) : -1;

    if (info && index == ourIndex) {
        objc_setAssociatedObject(sheet, &kTouSongFallbackInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[ZhuTiTouSong] 点击投送入口，弹出投送面板");
        presentTouSongFromTargetInfo(info);
        return;
    }

    // 官方按钮：透明转发给原始代理
    if (origDelegate && (id)origDelegate != sheet && [origDelegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) {
        [(id<WCActionSheetDelegate>)origDelegate actionSheet:(WCActionSheet *)sheet clickedButtonAtIndex:index];
    }
}

%hook WCActionSheet

- (void)showInView:(UIView *)view {
    injectTouSongIntoMenu(self);
    %orig;
}

- (void)show {
    injectTouSongIntoMenu(self);
    %orig;
}

%new
- (void)actionSheet:(WCActionSheet *)actionSheet clickedButtonAtIndex:(long long)index {
    handleTouSongItemClick(self, index);
}

%end

%hook WCMenuView

- (void)showInView:(UIView *)view {
    injectTouSongIntoMenu(self);
    %orig;
}

- (void)show {
    injectTouSongIntoMenu(self);
    %orig;
}

%new
- (void)actionSheet:(WCActionSheet *)actionSheet clickedButtonAtIndex:(long long)index {
    handleTouSongItemClick(self, index);
}

%end

// 将目标类的运行时方法/属性/成员变量 dump 到日志与文件，用于精确定位微信菜单真实 API
static void dumpTouSongRuntimeInfo(Class cls) {
    if (!cls) return;
    NSString *clsName = NSStringFromClass(cls);
    NSMutableString *s = [NSMutableString stringWithFormat:@"===== %@ =====\n", clsName];

    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    [s appendFormat:@"--- 方法 (%u) ---\n", mc];
    for (unsigned int i = 0; i < mc; i++) {
        [s appendFormat:@"- %@\n", NSStringFromSelector(method_getName(methods[i]))];
    }
    free(methods);

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    [s appendFormat:@"--- 属性 (%u) ---\n", pc];
    for (unsigned int i = 0; i < pc; i++) {
        [s appendFormat:@"@ %s\n", property_getName(props[i])];
    }
    free(props);

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    [s appendFormat:@"--- ivar (%u) ---\n", ic];
    for (unsigned int i = 0; i < ic; i++) {
        [s appendFormat:@"* %s %s\n", ivar_getTypeEncoding(ivars[i]), ivar_getName(ivars[i])];
    }
    free(ivars);
    [s appendString:@"\n"];

    NSLog(@"[ZhuTiTouSong-Runtime] %@", s);

    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"Preferences"];
    NSString *path = [dir stringByAppendingPathComponent:@"ZTTSMenuDump.txt"];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [d writeToFile:path atomically:YES];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
    }
}

// 扫描控制器 ivar，找到 NSMutableArray（菜单项容器）并追加菜单项
static BOOL appendTouSongMenuItemViaIvar(MMMenuController *menuVC, MMMenuItem *item) {
    Class cls = [menuVC class];
    Class itemCls = objc_getClass("MMMenuItem");
    while (cls && cls != [NSObject class]) {
        unsigned int ic = 0;
        Ivar *ivars = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || (strstr(type, "NSMutableArray") == NULL && strstr(type, "NSArray") == NULL)) continue;
            id arr = object_getIvar(menuVC, ivars[i]);
            if (![arr isKindOfClass:[NSMutableArray class]]) continue;
            // 空数组直接加；否则要求首元素是 MMMenuItem 类型，避免污染无关数组
            BOOL addIt = ([arr count] == 0);
            if (!addIt && itemCls) {
                id first = [arr firstObject];
                addIt = [first isKindOfClass:itemCls];
            }
            if (addIt) {
                [arr addObject:item];
                NSLog(@"[ZhuTiTouSong] ivar 命中容器 %s", ivar_getName(ivars[i]));
                return YES;
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return NO;
}

// 创建微信菜单项（MMMenuItem），点击回调 target=菜单控制器自身
static MMMenuItem *createTouSongMenuItem(MMMenuController *menuVC) {
    Class itemClass = objc_getClass("MMMenuItem");
    if (!itemClass) {
        NSLog(@"[ZhuTiTouSong] 未找到 MMMenuItem 类，无法注入菜单项");
        return nil;
    }
    SEL actionSel = NSSelectorFromString(@"touSongMenuAction:");
    MMMenuItem *item = nil;

    SEL fullInit = NSSelectorFromString(@"initWithTitle:icon:target:action:");
    if ([itemClass instancesRespondToSelector:fullInit]) {
        item = [(MMMenuItem *)[itemClass alloc] initWithTitle:@"投送" icon:nil target:menuVC action:actionSel];
    } else {
        SEL shortInit = NSSelectorFromString(@"initWithTarget:action:");
        if ([itemClass instancesRespondToSelector:shortInit]) {
            item = [(MMMenuItem *)[itemClass alloc] initWithTarget:menuVC action:actionSel];
            @try {
                if ([item respondsToSelector:@selector(setTitle:)]) [item setTitle:@"投送"];
                else [item setValue:@"投送" forKey:@"m_nsTitle"];
            } @catch (NSException *e) {}
        } else {
            item = [(MMMenuItem *)[itemClass alloc] init];
            @try {
                SEL setTitleSel = NSSelectorFromString(@"setTitle:");
                if ([item respondsToSelector:setTitleSel]) [item setTitle:@"投送"];
                else [item setValue:@"投送" forKey:@"m_nsTitle"];
            } @catch (NSException *e) {}
        }
    }
    return item;
}

// 尝试向已有菜单追加「投送」入口（多策略兜底）
static void injectTouSongIntoMMMenu(MMMenuController *menuVC) {
    if (!menuVC || !g_pendingTargetInfo) return;
    MMMenuItem *item = createTouSongMenuItem(menuVC);
    if (!item) return;

    objc_setAssociatedObject(menuVC, &kTouSongMenuInfoKey, g_pendingTargetInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 1) addMenuItem:
    if ([menuVC respondsToSelector:@selector(addMenuItem:)]) {
        [menuVC addMenuItem:item];
        g_pendingTargetInfo = nil;
        if ([menuVC respondsToSelector:@selector(reloadData)]) [menuVC reloadData];
        NSLog(@"[ZhuTiTouSong] 投送入口注入成功(MMMenuController-addMenuItem)");
        return;
    }

    // 2) 常见菜单项容器属性（NSMutableArray 直接追加）
    NSArray *keys = @[@"operationMenuItems", @"menuItems", @"m_arrMenuItems", @"menuItemArr"];
    for (NSString *k in keys) {
        id arr = nil;
        @try { arr = [menuVC valueForKey:k]; } @catch (NSException *e) {}
        if ([arr isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)arr addObject:item];
            g_pendingTargetInfo = nil;
            if ([menuVC respondsToSelector:@selector(reloadData)]) [menuVC reloadData];
            NSLog(@"[ZhuTiTouSong] 投送入口注入成功(MMMenuController-%@)", k);
            return;
        }
    }

    // 3) ivar 扫描兜底
    if (appendTouSongMenuItemViaIvar(menuVC, item)) {
        g_pendingTargetInfo = nil;
        if ([menuVC respondsToSelector:@selector(reloadData)]) [menuVC reloadData];
        return;
    }

    NSLog(@"[ZhuTiTouSong] MMMenuController 无可用添加方法，注入失败");
}

%hook MMMenuController

- (void)viewDidLoad {
    %orig;
    // 首次弹出菜单时 dump 运行时结构，用于定位真实注入 API
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dumpTouSongRuntimeInfo([self class]);
        dumpTouSongRuntimeInfo(objc_getClass("MMMenuItem"));
        dumpTouSongRuntimeInfo(objc_getClass("WCMessageCell"));
    });
    injectTouSongIntoMMMenu(self);
}

- (void)setMenuItems:(NSArray *)items {
    if (g_pendingTargetInfo) {
        MMMenuItem *item = createTouSongMenuItem(self);
        if (item) {
            NSMutableArray *arr = [items mutableCopy] ?: [NSMutableArray array];
            [arr addObject:item];
            objc_setAssociatedObject(self, &kTouSongMenuInfoKey, g_pendingTargetInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            g_pendingTargetInfo = nil;
            items = arr;
            NSLog(@"[ZhuTiTouSong] 投送入口注入成功(MMMenuController-setMenuItems)");
        }
    }
    %orig(items);
}

- (void)setMenuItemArr:(NSArray *)items {
    if (g_pendingTargetInfo) {
        MMMenuItem *item = createTouSongMenuItem(self);
        if (item) {
            NSMutableArray *arr = [items mutableCopy] ?: [NSMutableArray array];
            [arr addObject:item];
            objc_setAssociatedObject(self, &kTouSongMenuInfoKey, g_pendingTargetInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            g_pendingTargetInfo = nil;
            items = arr;
            NSLog(@"[ZhuTiTouSong] 投送入口注入成功(MMMenuController-setMenuItemArr)");
        }
    }
    %orig(items);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    injectTouSongIntoMMMenu(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    injectTouSongIntoMMMenu(self);
}

%new
- (void)touSongMenuAction:(id)sender {
    NSDictionary *info = objc_getAssociatedObject(self, &kTouSongMenuInfoKey);
    if (info) {
        objc_setAssociatedObject(self, &kTouSongMenuInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[ZhuTiTouSong] 点击投送入口，弹出投送面板");
        presentTouSongFromTargetInfo(info);
    }
}

%end

%end

// 微信版本最低适配 8.0.73，最高不上限；低于最低版本返回 NO
static BOOL isWeChatVersionSupported(void) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!version || version.length == 0) {
        return YES; // 无法获取版本号时不做限制（最高不上限）
    }
    // 按数字分段比较，兼容 8.0.73 / 8.0.73.1 / 8.0.73beta 等形式
    return ([version compare:@"8.0.73" options:NSNumericSearch] != NSOrderedAscending);
}

%ctor {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 微信版本最低适配 8.0.73，最高不上限；低于最低版本不注入
        if (!isWeChatVersionSupported()) {
            NSLog(@"[ZhuTiTouSong] 微信版本低于 8.0.73，插件未生效");
            return;
        }

        %init(chajianguanlijieru);
        %init(changanyemenu);
        %init(zhilingtousong);
    });
}