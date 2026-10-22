//
//  RBRootVC.m — 主界面
//
//  布局沿用原版（分段：全部/运行中/真后台/自启 + 搜索 + 左右滑动操作），
//  底部新增一条「一键加速」。原版没有这个键，它的清内存要一个个 App 点「杀后台」。
//
#import "RB.h"

static UIColor *RBAccent(void) { return [UIColor colorWithRed:0.16 green:0.78 blue:0.55 alpha:1]; }
static UIColor *RBWarn(void)   { return [UIColor colorWithRed:1.00 green:0.42 blue:0.35 alpha:1]; }

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
    _nameLabel.frame = CGRectMake(tx, h / 2.0 - 20, w - tx - 96, 22);
    _bidLabel.frame  = CGRectMake(tx, h / 2.0 + 2, w - tx - 96, 16);
    _stateLabel.frame = CGRectMake(w - 100, h / 2.0 - 9, 86, 18);
    _spin.frame = CGRectMake(w - 34, (h - 20) / 2.0, 20, 20);
}

- (void)bind:(RBAppInfo *)info {
    self.nameLabel.text = info.name;
    self.bidLabel.text = info.bundleID;
    self.iconView2.image = info.icon ?: [UIImage systemImageNamed:@"app.dashed"];

    NSMutableArray *tags = [NSMutableArray array];
    if (info.hasBackstage) [tags addObject:@"真后台"];
    if (info.hasAutoStart) [tags addObject:@"自启"];
    if (info.hasSuicide)   [tags addObject:@"切走即杀"];

    if (info.isRunning) {
        self.spin.hidden = NO;
        [self.spin startAnimating];
        self.stateLabel.text = tags.count ? [tags componentsJoinedByString:@"·"] : @"运行中";
        self.stateLabel.textColor = tags.count ? RBAccent() : [UIColor colorWithWhite:1 alpha:0.45];
    } else {
        [self.spin stopAnimating];
        self.stateLabel.text = tags.count ? [tags componentsJoinedByString:@"·"] : @"未运行";
        self.stateLabel.textColor = tags.count ? RBAccent() : [UIColor colorWithWhite:1 alpha:0.28];
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
@property (nonatomic, assign) NSInteger tab;      // 0 全部 1 运行中 2 真后台 3 自启
@property (nonatomic, copy)   NSString *query;
@property (nonatomic, assign) BOOL loading;

// 前置声明（避免方法定义顺序导致的隐式声明告警）
- (void)buildSeg;
- (void)buildTable;
- (void)buildBoost;
- (void)buildSearch;
- (void)reload;
- (void)applyFilter;
- (void)refreshMemoryLabel;
- (void)segChanged;
- (void)appDidBecomeActive;
- (void)toggleBackstage:(RBAppInfo *)info;
- (void)enableAllRunning;
- (void)tapBoost;
- (void)doBoost;
- (void)toast:(NSString *)s;
@end

@implementation RBRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.06 blue:0.075 alpha:1];
    self.title = @"真后台 Pro";

    self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor = [UIColor whiteColor];

    [self buildSeg];
    [self buildTable];
    [self buildBoost];
    [self buildSearch];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全部真后台" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(enableAllRunning)];

    [self reload];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshMemoryLabel];
}

- (void)appDidBecomeActive {
    [self refreshMemoryLabel];
    [self reload];
}

#pragma mark 布局

- (void)buildSeg {
    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"运行中", @"真后台", @"自启"]];
    self.seg.selectedSegmentIndex = 0;
    self.seg.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                             forState:UIControlStateNormal];
    [self.seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    self.seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.seg];
    [NSLayoutConstraint activateConstraints:@[
        [self.seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.seg.heightAnchor constraintEqualToConstant:34],
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

        [self.memLabel.topAnchor constraintEqualToAnchor:bar.topAnchor constant:10],
        [self.memLabel.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:20],
        [self.memLabel.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-20],

        [self.boostButton.topAnchor constraintEqualToAnchor:self.memLabel.bottomAnchor constant:8],
        [self.boostButton.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [self.boostButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [self.boostButton.heightAnchor constraintEqualToConstant:52],
        [self.boostButton.bottomAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.bottomAnchor constant:-10],

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
    if (self.loading) return;
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = [RBProcesses installedApps];
        NSDictionary *running = [RBProcesses runningPids];
        RBStore *store = [RBStore shared];

        for (RBAppInfo *i in apps) {
            NSNumber *pid = running[i.bundleID];
            i.isRunning = pid != nil;
            i.pid = pid.intValue;
            i.hasBackstage = [store.backstageIDs containsObject:i.bundleID];
            i.hasAutoStart = [store.autoStartIDs containsObject:i.bundleID];
            i.hasSuicide = [store.suicideIDs containsObject:i.bundleID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = apps;
            self.loading = NO;
            [self applyFilter];
            [self refreshMemoryLabel];
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

- (void)refreshMemoryLabel {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        double used = [RBProcesses usedMemoryMB];
        double freeMB = [RBProcesses freeMemoryMB];
        double est = [RBBooster estimatedReclaimMB];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.memLabel.text = [NSString stringWithFormat:@"已用 %@ · 可用 %@ · 可清理约 %@",
                                  RBHumanMB(used), RBHumanMB(freeMB), RBHumanMB(est)];
        });
    });
}

- (void)segChanged {
    self.tab = self.seg.selectedSegmentIndex;
    [self applyFilter];
}

#pragma mark 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RBAppCell *c = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    [c bind:self.shown[indexPath.row]];
    return c;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    RBAppInfo *info = self.shown[indexPath.row];
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
    RBAppInfo *info = self.shown[indexPath.row];

    UIContextualAction *kill = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"杀后台"
                                                                    handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        if (!info.isRunning) { done(NO); return; }
        [RBProcesses killApp:info.bundleID pid:info.pid];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self reload]; });
        done(YES);
    }];
    kill.backgroundColor = RBWarn();

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

    return [UISwipeActionsConfiguration configurationWithActions:@[kill, autoAct]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RBAppInfo *info = self.shown[indexPath.row];

    NSString *mem = @"未运行";
    if (info.isRunning) {
        double mb = [RBBooster footprintMBForPid:info.pid];
        mem = mb > 0 ? [NSString stringWithFormat:@"占用 %@", RBHumanMB(mb)] : @"运行中";
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:info.name
                         message:[NSString stringWithFormat:@"%@\n%@\n%@",
                                  info.bundleID, info.isRunning ? @"运行中" : @"未运行", mem]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction actionWithTitle:(info.hasBackstage ? @"关闭真后台" : @"开启真后台")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self toggleBackstage:info]; }]];
    if (info.isRunning) {
        [ac addAction:[UIAlertAction actionWithTitle:@"杀后台" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            [RBProcesses killApp:info.bundleID pid:info.pid];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self reload]; });
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:(info.hasSuicide ? @"取消「切走即杀」" : @"开启「切走即杀」")
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
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark 动作

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
    NSArray *cands = [RBBooster candidatesProtecting:[RBStore shared].backstageIDs];
    if (cands.count == 0) { [self toast:@"没有可清理的后台进程"]; return; }

    double est = 0;
    NSMutableString *list = [NSMutableString string];
    for (NSDictionary *d in cands) {
        est += [d[@"mb"] doubleValue];
        if (list.length < 300) {
            [list appendFormat:@"· %@ %.0f MB\n", d[@"bundleID"], [d[@"mb"] doubleValue]];
        }
    }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"将结束 %lu 个后台进程", (unsigned long)cands.count]
                         message:[NSString stringWithFormat:@"预计释放约 %@\n\n%@",
                                  RBHumanMB(est), list]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"开始加速" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) { [self doBoost]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)doBoost {
    self.boostButton.enabled = NO;
    [self.boostButton setTitle:@"正在加速…" forState:UIControlStateNormal];

    NSSet *protect = [[RBStore shared].backstageIDs copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *r = [RBBooster boostProtecting:protect];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.boostButton.enabled = YES;
            [self.boostButton setTitle:@"一键加速" forState:UIControlStateNormal];
            [self refreshMemoryLabel];
            [self reload];

            NSString *msg = [NSString stringWithFormat:@"结束 %@ 个进程，释放 %@\n可用内存 %@ → %@",
                             r[@"killed"], RBHumanMB([r[@"freedMB"] doubleValue]),
                             RBHumanMB([r[@"beforeMB"] doubleValue]),
                             RBHumanMB([r[@"afterMB"] doubleValue])];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"加速完成"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        });
    });
}

- (void)toast:(NSString *)s {
    RBLog(@"%@", s);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:s
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [ac dismissViewControllerAnimated:YES completion:nil]; });
    }];
}

#pragma mark 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.query = searchController.searchBar.text;
    [self applyFilter];
}

@end
