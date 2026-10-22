//
//  RBRootVC.m — 主界面
//
//  布局沿用原版（分段 + 搜索 + 左右滑动操作），底部一条「一键加速」。
//
//  1.1.0 新增：
//    · 「保留名单（锁定）」：右滑或详情里一键锁定，锁住的 App 加速/清理永不碰
//    · 加速前的弹窗明确列出「已锁定 N 个不会被结束」，不是静默跳过
//    · 诊断入口：显示日志文件位置、把上次崩溃现场直接摊开
//    · 安全模式：上次启动崩过，这次就不自动枚举（先让界面能开，点刷新再试）
//
//  仍然保留的界面层防护：
//    · 表格取值一律走 infoAtIndex:，越界返回 nil（刷新瞬间数据变短不会 NSRangeException）
//    · 枚举全在后台线程，按钮先变「正在统计…」
//    · 弹窗统一走 presentAlert:，避免 already presenting 导致提示不显示
//
#import "RB.h"

static UIColor *RBAccent(void) { return [UIColor colorWithRed:0.16 green:0.78 blue:0.55 alpha:1]; }
static UIColor *RBWarn(void)   { return [UIColor colorWithRed:1.00 green:0.42 blue:0.35 alpha:1]; }
static UIColor *RBLock(void)   { return [UIColor colorWithRed:1.00 green:0.78 blue:0.28 alpha:1]; }

#pragma mark - Cell

@interface RBAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView2;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *bidLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spin;
- (void)bind:(RBAppInfo *)info;
@end

@implementation RBAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        UIView *bg = [UIView new];
        bg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        bg.layer.cornerRadius = 14;
        self.backgroundView = bg;
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        self.selectedBackgroundView.layer.cornerRadius = 14;

        _iconView2 = [UIImageView new];
        _iconView2.layer.cornerRadius = 11;
        _iconView2.layer.masksToBounds = YES;
        _iconView2.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_iconView2];

        _nameLabel = [UILabel new];
        _nameLabel.textColor = [UIColor whiteColor];
        _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_nameLabel];

        _bidLabel = [UILabel new];
        _bidLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        _bidLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        _bidLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_bidLabel];

        _stateLabel = [UILabel new];
        _stateLabel.textColor = RBAccent();
        _stateLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _stateLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_stateLabel];

        _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spin.color = RBAccent();
        _spin.hidesWhenStopped = YES;
        [self.contentView addSubview:_spin];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat w = self.contentView.bounds.size.width;
    _iconView2.frame = CGRectMake(16, (h - 44) / 2.0, 44, 44);
    CGFloat tx = CGRectGetMaxX(_iconView2.frame) + 12;
    CGFloat stateW = 104;
    CGFloat textW = MAX(40, w - tx - stateW - 12);
    _nameLabel.frame = CGRectMake(tx, h / 2.0 - 20, textW, 22);
    _bidLabel.frame  = CGRectMake(tx, h / 2.0 + 2, textW, 16);
    _stateLabel.frame = CGRectMake(w - stateW - 12, h / 2.0 - 9, stateW, 18);
    _spin.frame = CGRectMake(w - 26, (h - 20) / 2.0, 20, 20);
}

- (void)bind:(RBAppInfo *)info {
    self.nameLabel.text = info.name;
    self.bidLabel.text = info.bundleID;
    self.iconView2.image = info.icon ?: [UIImage systemImageNamed:@"app.dashed"];

    // 标签最多显示两个，其余折成「+N」—— 四个标签挤在一行会互相顶掉
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    if (info.locked)       [tags addObject:@"已锁定"];
    if (info.hasBackstage) [tags addObject:@"真后台"];
    if (info.hasSuicide)   [tags addObject:@"退出即杀"];
    if (info.hasAutoStart) [tags addObject:@"自启"];

    NSString *state = nil;
    if (tags.count == 0) {
        state = info.isRunning ? @"运行中" : @"未运行";
    } else if (tags.count <= 2) {
        state = [tags componentsJoinedByString:@"·"];
    } else {
        state = [NSString stringWithFormat:@"%@ +%lu", tags[0], (unsigned long)(tags.count - 1)];
    }
    self.stateLabel.text = state;

    UIColor *onColor = info.locked ? RBLock() : RBAccent();
    if (info.isRunning) {
        self.spin.hidden = NO;
        [self.spin startAnimating];
        self.stateLabel.textColor = tags.count ? onColor : [UIColor colorWithWhite:1 alpha:0.45];
    } else {
        [self.spin stopAnimating];
        self.stateLabel.textColor = tags.count ? onColor : [UIColor colorWithWhite:1 alpha:0.28];
    }
}

@end

#pragma mark - VC

@interface RBRootVC () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UIButton *boostButton;
@property (nonatomic, strong) UILabel *memLabel;

@property (nonatomic, strong) NSArray<RBAppInfo *> *allApps;
@property (nonatomic, strong) NSArray<RBAppInfo *> *shown;
@property (nonatomic, assign) NSInteger tab;      // 0 全部 1 运行 2 保活 3 自启 4 锁定
@property (nonatomic, copy)   NSString *query;

@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL pendingReload;
@property (nonatomic, assign) BOOL boostBusy;
@property (nonatomic, assign) BOOL safeMode;
@property (nonatomic, assign) BOOL crashPrompted;

@property (nonatomic, assign) double usedMB;
@property (nonatomic, assign) double freeMB;
@property (nonatomic, assign) double estimateMB;
@property (nonatomic, assign) BOOL hasMemory;

- (void)buildSeg;
- (void)buildTable;
- (void)buildBoost;
- (void)buildSearch;
- (void)reload;
- (void)applyFilter;
- (void)updateMemoryLabel;
- (void)segChanged;
- (void)appDidBecomeActive;
- (void)toggleBackstage:(RBAppInfo *)info;
- (void)toggleLock:(RBAppInfo *)info;
- (void)enableAllRunning;
- (void)tapBoost;
- (void)doBoostWithCandidates:(NSArray *)cands;
- (void)toast:(NSString *)s;
- (void)presentAlert:(UIAlertController *)ac;
- (void)reloadAfterDelay;
- (void)showMenu;
- (void)showDiag;
- (void)promptLastCrashIfAny;
@end

@implementation RBRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.06 blue:0.075 alpha:1];
    self.title = @"真后台 Pro";

    self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor = [UIColor whiteColor];

    // 上次启动崩过就先别自动枚举 —— 先保证界面能打开，让用户看到崩溃记录
    self.safeMode = (RBReadLastCrash().length > 0);

    [self buildSeg];
    [self buildTable];
    [self buildBoost];
    [self buildSearch];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                     target:self action:@selector(showMenu)];

    if (self.safeMode) {
        self.memLabel.text = @"上次启动异常，已进入安全模式 · 点右上「刷新」重试";
    } else {
        [self reload];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self promptLastCrashIfAny];
    if (!self.safeMode) [self reload];
}

- (void)appDidBecomeActive {
    if (!self.safeMode) [self reload];
}

#pragma mark 布局

- (void)buildSeg {
    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"运行", @"保活", @"自启", @"锁定"]];
    self.seg.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        self.seg.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    }
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                             forState:UIControlStateNormal];
    [self.seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    self.seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.seg];
    [NSLayoutConstraint activateConstraints:@[
        [self.seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.seg.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)buildTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 68;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.contentInset = UIEdgeInsetsMake(6, 0, 96, 0);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[RBAppCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
}

- (void)buildBoost {
    UIView *bar = [UIView new];
    bar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    self.memLabel = [UILabel new];
    self.memLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.memLabel.font = [UIFont systemFontOfSize:12];
    self.memLabel.numberOfLines = 2;
    self.memLabel.text = @"正在读取内存…";
    self.memLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.memLabel];

    self.boostButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.boostButton setTitle:@"一键加速" forState:UIControlStateNormal];
    [self.boostButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.boostButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    self.boostButton.backgroundColor = RBAccent();
    self.boostButton.layer.cornerRadius = 16;
    [self.boostButton addTarget:self action:@selector(tapBoost) forControlEvents:UIControlEventTouchUpInside];
    self.boostButton.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.boostButton];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.memLabel.topAnchor constraintEqualToAnchor:bar.topAnchor constant:8],
        [self.memLabel.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:20],
        [self.memLabel.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-20],

        [self.boostButton.topAnchor constraintEqualToAnchor:self.memLabel.bottomAnchor constant:6],
        [self.boostButton.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [self.boostButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [self.boostButton.heightAnchor constraintEqualToConstant:50],
        [self.boostButton.bottomAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.bottomAnchor constant:-8],

        [self.tableView.topAnchor constraintEqualToAnchor:self.seg.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:bar.topAnchor],
    ]];
}

- (void)buildSearch {
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索 App 或 bundle id";
    self.search.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.search.searchBar.tintColor = [UIColor whiteColor];
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

#pragma mark 数据

- (void)reload {
    if (self.loading) {
        self.pendingReload = YES;
        return;
    }
    self.loading = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = [RBProcesses installedApps];
        NSDictionary *running = [RBProcesses runningPids];
        RBStore *store = [RBStore shared];
        NSSet *protect = [store allProtectedIDs];

        for (RBAppInfo *i in apps) {
            NSNumber *pid = running[i.bundleID];
            i.isRunning = pid != nil;
            i.pid = pid.intValue;
            i.hasBackstage = [store.backstageIDs containsObject:i.bundleID];
            i.hasAutoStart = [store.autoStartIDs containsObject:i.bundleID];
            i.hasSuicide = [store.suicideIDs containsObject:i.bundleID];
            i.locked = [store.lockIDs containsObject:i.bundleID];
        }

        // 内存与「可清理」只在这里算一次，别在每次刷新界面时重算
        double used = [RBProcesses usedMemoryMB];
        double freeMB = [RBProcesses freeMemoryMB];
        BOOL hasMemory = (used + freeMB) > 1.0;
        double est = 0;
        for (NSDictionary *d in [RBBooster candidatesProtecting:protect]) {
            est += [d[@"mb"] doubleValue];
        }

        NSUInteger lockCount = store.lockIDs.count;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = [apps copy];
            self.usedMB = used;
            self.freeMB = freeMB;
            self.estimateMB = est;
            self.hasMemory = hasMemory;
            self.loading = NO;
            if (apps.count > 0) self.safeMode = NO;    // 枚举成功就退出安全模式
            [self applyFilter];
            [self updateMemoryLabel];

            if (lockCount > 0) {
                self.memLabel.text = [self.memLabel.text stringByAppendingFormat:@" · 锁定 %lu",
                                      (unsigned long)lockCount];
            }

            if (self.pendingReload) {
                self.pendingReload = NO;
                [self reload];
            }
        });
    });
}

- (void)applyFilter {
    NSString *q = [self.query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    NSMutableArray *out = [NSMutableArray array];
    for (RBAppInfo *i in self.allApps) {
        if (self.tab == 1 && !i.isRunning) continue;
        if (self.tab == 2 && !i.hasBackstage) continue;
        if (self.tab == 3 && !i.hasAutoStart) continue;
        if (self.tab == 4 && !i.locked) continue;
        if (q.length) {
            BOOL hit = [i.name.lowercaseString containsString:q] ||
                       [i.bundleID.lowercaseString containsString:q];
            if (!hit) continue;
        }
        [out addObject:i];
    }
    self.shown = out;
    [self.tableView reloadData];
}

- (void)updateMemoryLabel {
    if (!self.hasMemory) {
        if (!self.safeMode) self.memLabel.text = @"内存信息读取失败";
        return;
    }
    self.memLabel.text = [NSString stringWithFormat:@"已用 %@ · 可用 %@ · 可清理约 %@",
                          RBHumanMB(self.usedMB), RBHumanMB(self.freeMB), RBHumanMB(self.estimateMB)];
}

- (void)reloadAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reload]; });
}

- (void)segChanged {
    self.tab = self.seg.selectedSegmentIndex;
    [self applyFilter];
}

#pragma mark 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shown.count;
}

- (RBAppInfo *)infoAtIndex:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.shown.count) return nil;   // 刷新瞬间的越界防护
    return self.shown[row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RBAppCell *c = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    RBAppInfo *info = [self infoAtIndex:indexPath.row];
    if (info) [c bind:info];
    return c;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    RBAppInfo *info = [self infoAtIndex:indexPath.row];
    if (!info) return nil;
    BOOL on = info.hasBackstage;
    UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                    title:(on ? @"关闭真后台" : @"开启真后台")
                                                                  handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [self toggleBackstage:info];
        done(YES);
    }];
    a.backgroundColor = on ? [UIColor grayColor] : RBAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[a]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    RBAppInfo *info = [self infoAtIndex:indexPath.row];
    if (!info) return nil;

    UIContextualAction *lockAct = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:(info.locked ? @"取消锁定" : @"锁定保留")
                                                                   handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [self toggleLock:info];
        done(YES);
    }];
    lockAct.backgroundColor = RBLock();

    UIContextualAction *autoAct = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:(info.hasAutoStart ? @"取消自启" : @"加入自启")
                                                                   handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        RBStore *s = [RBStore shared];
        if (info.hasAutoStart) [s.autoStartIDs removeObject:info.bundleID];
        else [s.autoStartIDs addObject:info.bundleID];
        [s save];
        [self reload];
        done(YES);
    }];
    autoAct.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1];

    UIContextualAction *kill = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"杀后台"
                                                                    handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        if (!info.isRunning) { done(NO); return; }
        if (info.locked) {
            [self toast:[NSString stringWithFormat:@"%@ 已锁定，先取消锁定", info.name]];
            done(NO);
            return;
        }
        if (![RBProcesses killApp:info.bundleID pid:info.pid]) {
            [self toast:[NSString stringWithFormat:@"%@ 没能结束（系统拒绝）", info.name]];
        }
        [self reloadAfterDelay];
        done(YES);
    }];
    kill.backgroundColor = RBWarn();

    return [UISwipeActionsConfiguration configurationWithActions:@[kill, autoAct, lockAct]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RBAppInfo *info = [self infoAtIndex:indexPath.row];
    if (!info) return;

    NSString *mem = @"未运行";
    if (info.isRunning) {
        double mb = [RBBooster footprintMBForPid:info.pid];
        mem = mb > 0 ? [NSString stringWithFormat:@"占用 %@", RBHumanMB(mb)] : @"运行中（占用未知）";
    }
    NSString *lockNote = info.locked ? @"已锁定 · 一键加速不会结束它" : @"未锁定 · 一键加速可能结束它";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:info.name
                         message:[NSString stringWithFormat:@"%@\n%@\n%@\n%@",
                                  info.bundleID, info.isRunning ? @"运行中" : @"未运行", mem, lockNote]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    // 锁定放在第一个：用户最常做的决定就是「这个别动」
    [ac addAction:[UIAlertAction actionWithTitle:(info.locked ? @"取消锁定" : @"锁定（加速时保留）")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self toggleLock:info]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:(info.hasBackstage ? @"关闭真后台" : @"开启真后台")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self toggleBackstage:info]; }]];
    if (info.isRunning) {
        [ac addAction:[UIAlertAction actionWithTitle:@"杀后台" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            if (info.locked) {
                [self toast:@"已锁定，先取消锁定再杀"];
                return;
            }
            [RBProcesses killApp:info.bundleID pid:info.pid];
            [self reloadAfterDelay];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:(info.hasSuicide ? @"取消「退出即杀」" : @"开启「退出即杀」")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        RBStore *s = [RBStore shared];
        if (info.hasSuicide) [s.suicideIDs removeObject:info.bundleID];
        else [s.suicideIDs addObject:info.bundleID];
        [s save];
        [self reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    ac.popoverPresentationController.sourceView = tableView;
    ac.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentAlert:ac];
}

#pragma mark 动作

/// 锁定 / 解锁。锁定后这个 App 会同时被排除在「一键加速」和「退出即杀」之外，
/// 真后台也一并关闭 —— 锁定的意思就是「别管它」，别搞两套语义互相打架。
- (void)toggleLock:(RBAppInfo *)info {
    RBStore *s = [RBStore shared];
    if (info.locked) {
        [s.lockIDs removeObject:info.bundleID];
        [s save];
        [self toast:[NSString stringWithFormat:@"%@ 已解锁，下次加速可能被结束", info.name]];
    } else {
        [s.lockIDs addObject:info.bundleID];
        // 锁定与「退出即杀」天然冲突，锁定优先，把冲突项移除
        if ([s.suicideIDs containsObject:info.bundleID]) {
            [s.suicideIDs removeObject:info.bundleID];
        }
        [s save];
        [self toast:[NSString stringWithFormat:@"%@ 已锁定，加速时不会动它", info.name]];
    }
    [self reload];
}

- (void)toggleBackstage:(RBAppInfo *)info {
    RBStore *s = [RBStore shared];
    if (info.hasBackstage) {
        [[RBBackstage shared] disableForBundle:info.bundleID];
        [s.backstageIDs removeObject:info.bundleID];
        [s save];
        [self reload];
        return;
    }
    if (!info.isRunning) {
        [self toast:@"先打开这个 App，再开真后台"];
        return;
    }
    NSError *err = nil;
    if ([[RBBackstage shared] enableForBundle:info.bundleID pid:info.pid error:&err]) {
        [s.backstageIDs addObject:info.bundleID];
        [s save];
        [self toast:[NSString stringWithFormat:@"%@ 已进入真后台", info.name]];
    } else {
        [self toast:[NSString stringWithFormat:@"失败：%@", err.localizedDescription ?: @"未知原因"]];
    }
    [self reload];
}

- (void)enableAllRunning {
    NSMutableArray *targets = [NSMutableArray array];
    for (RBAppInfo *i in self.allApps) {
        if (i.isRunning && !i.isSystem && !i.hasBackstage) [targets addObject:i];
    }
    if (targets.count == 0) { [self toast:@"没有需要处理的运行中 App"]; return; }

    NSUInteger ok = 0;
    RBStore *s = [RBStore shared];
    for (RBAppInfo *i in targets) {
        if ([[RBBackstage shared] enableForBundle:i.bundleID pid:i.pid error:NULL]) {
            [s.backstageIDs addObject:i.bundleID];
            ok++;
        }
    }
    [s save];
    [self toast:[NSString stringWithFormat:@"已开启 %lu/%lu 个", (unsigned long)ok, (unsigned long)targets.count]];
    [self reload];
}

- (void)tapBoost {
    if (self.boostBusy) return;
    self.boostBusy = YES;
    self.boostButton.enabled = NO;
    [self.boostButton setTitle:@"正在统计…" forState:UIControlStateNormal];

    NSSet *protect = [[RBStore shared] allProtectedIDs];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *cands = [RBBooster candidatesProtecting:protect];
        NSArray *locked = [RBBooster lockedCandidatesProtecting:protect];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.boostBusy = NO;
            self.boostButton.enabled = YES;
            [self.boostButton setTitle:@"一键加速" forState:UIControlStateNormal];

            // 锁定项的名字要换成 App 显示名，bundleID 对普通用户没意义
            NSMutableDictionary<NSString *, NSString *> *nameMap = [NSMutableDictionary dictionary];
            for (RBAppInfo *i in self.allApps) {
                if (i.bundleID.length) nameMap[i.bundleID] = i.name ?: i.bundleID;
            }

            NSMutableString *lockLine = [NSMutableString string];
            if (locked.count > 0) {
                double kept = 0;
                NSMutableArray<NSString *> *names = [NSMutableArray array];
                for (NSDictionary *d in locked) {
                    kept += [d[@"mb"] doubleValue];
                    NSString *bid = d[@"bundleID"];
                    [names addObject:nameMap[bid] ?: bid];
                }
                NSUInteger show = MIN(names.count, 5u);
                [lockLine appendFormat:@"🔒 已锁定跳过 %lu 个（约 %@）：%@%@\n\n",
                 (unsigned long)locked.count, RBHumanMB(kept),
                 [[names subarrayWithRange:NSMakeRange(0, show)] componentsJoinedByString:@"、"],
                 names.count > show ? @"…" : @""];
            }

            if (cands.count == 0) {
                NSString *msg = lockLine.length
                    ? [lockLine stringByAppendingString:@"除此之外没有可清理的后台进程。"]
                    : @"没有可清理的后台进程（系统 App、8MB 以下的不动）。";
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"无需加速"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentAlert:ac];
                return;
            }

            double est = 0;
            NSMutableString *list = [NSMutableString string];
            NSUInteger shown = 0;
            for (NSDictionary *d in cands) {
                est += [d[@"mb"] doubleValue];
                if (shown < 6) {
                    NSString *bid = d[@"bundleID"];
                    [list appendFormat:@"· %@ %@%@\n",
                     nameMap[bid] ?: bid,
                     [d[@"estimated"] boolValue] ? @"~" : @"",
                     RBHumanMB([d[@"mb"] doubleValue])];
                    shown++;
                }
            }
            if (cands.count > shown) {
                [list appendFormat:@"… 另有 %lu 个", (unsigned long)(cands.count - shown)];
            }

            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:[NSString stringWithFormat:@"将结束 %lu 个后台进程", (unsigned long)cands.count]
                                 message:[NSString stringWithFormat:@"%@预计释放约 %@\n\n%@",
                                          lockLine, RBHumanMB(est), list]
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"开始加速" style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) { [self doBoostWithCandidates:cands]; }]];
            [self presentAlert:ac];
        });
    });
}

- (void)doBoostWithCandidates:(NSArray *)cands {
    self.boostBusy = YES;
    self.boostButton.enabled = NO;
    [self.boostButton setTitle:@"正在加速…" forState:UIControlStateNormal];

    NSSet *protect = [[RBStore shared] allProtectedIDs];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *r = [RBBooster boostProtecting:protect];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.boostBusy = NO;
            self.boostButton.enabled = YES;
            [self.boostButton setTitle:@"一键加速" forState:UIControlStateNormal];

            NSMutableString *msg = [NSMutableString stringWithFormat:
                @"结束 %@ 个进程\n释放 %@（可用 %@ → %@）\n失败 %@ 个",
                r[@"killed"], RBHumanMB([r[@"freedMB"] doubleValue]),
                RBHumanMB([r[@"beforeMB"] doubleValue]),
                RBHumanMB([r[@"afterMB"] doubleValue]), r[@"failed"]];

            NSUInteger lockedSkipped = [r[@"lockedSkipped"] unsignedIntegerValue];
            if (lockedSkipped > 0) {
                [msg appendFormat:@"\n\n🔒 锁定保留 %lu 个（约 %@），没有被碰",
                 (unsigned long)lockedSkipped, RBHumanMB([r[@"lockedKeptMB"] doubleValue])];
            }

            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"加速完成"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentAlert:ac];
            [self reload];
        });
    });
}

#pragma mark 菜单 / 诊断

- (void)showMenu {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"全部开启真后台" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self enableAllRunning]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"诊断信息 / 日志位置" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self showDiag]; }]];
    NSString *crash = RBReadLastCrash();
    if (crash.length) {
        [ac addAction:[UIAlertAction actionWithTitle:@"查看上次崩溃记录" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            self.crashPrompted = NO;
            [self promptLastCrashIfAny];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"清除崩溃记录" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            RBDismissCrash();
            self.safeMode = NO;
            [self toast:@"已清除，重试正常加载"];
            [self reload];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    ac.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentAlert:ac];
}

- (void)showDiag {
    NSString *crash = RBReadLastCrash();
    NSString *msg = [NSString stringWithFormat:
        @"版本 %@\n"
        @"日志目录：\n%@\n\n"
        @"用「文件」App → 我的 iPhone → 真后台 Pro，可以直接看到并分享：\n"
        @"· RealBG-log.txt（运行日志）\n"
        @"· RealBG-crash.txt（崩溃记录）\n\n"
        @"上次崩溃：%@\n"
        @"安全模式：%@\n"
        @"已加载 App 数：%lu",
        RB_VERSION,
        RBLogDirPath(),
        crash.length ? [NSString stringWithFormat:@"有（%lu 字符）", (unsigned long)crash.length] : @"无",
        self.safeMode ? @"开" : @"关",
        (unsigned long)self.allApps.count];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"诊断信息"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentAlert:ac];
}

/// 启动时如果发现上次崩过，直接把现场摊给用户看。
/// 只弹一次，看完清楚了再从菜单里清掉。
- (void)promptLastCrashIfAny {
    if (self.crashPrompted) return;
    NSString *crash = RBReadLastCrash();
    if (crash.length == 0) return;
    self.crashPrompted = YES;

    NSString *body = crash.length > 900 ? [[crash substringToIndex:900] stringByAppendingString:@"\n…（完整内容见 RealBG-crash.txt）"] : crash;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"上次启动异常"
                         message:[NSString stringWithFormat:@"已进入安全模式（不自动扫描，界面可以先打开）。\n\n%@\n\n完整记录：文件 App → 我的 iPhone → 真后台 Pro → RealBG-crash.txt", body]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清除并重试" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        RBDismissCrash();
        self.safeMode = NO;
        [self reload];
    }]];
    [self presentAlert:ac];
}

#pragma mark 弹窗

/// 已经有弹窗在显示时直接 present 会失败（控制台报 already presenting，用户什么也看不到）。
/// 统一走这里：先关掉在显示的，再弹新的。
- (void)presentAlert:(UIAlertController *)ac {
    UIViewController *top = self.presentedViewController;
    if (top && !top.isBeingDismissed) {
        [top dismissViewControllerAnimated:NO completion:^{
            if (!self.presentedViewController && self.view.window) {
                [self presentViewController:ac animated:YES completion:nil];
            }
        }];
        return;
    }
    if (self.view.window == nil) return;      // 不在窗口里就别弹
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)toast:(NSString *)s {
    RBLog(@"%@", s);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:s
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentAlert:ac];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ac.presentingViewController) [ac dismissViewControllerAnimated:YES completion:nil];
    });
}

#pragma mark 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.query = searchController.searchBar.text;
    [self applyFilter];
}

@end
