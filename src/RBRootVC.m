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
/// 占用内存（第二行，右下角）。用户看不到数字时只能靠猜「为什么这个没被清理」，
/// 所以把每个运行中 App 的实时占用直接摆出来。
@property (nonatomic, strong) UILabel *memLabel;
@property (nonatomic, strong) UIView *dot;
- (void)bind:(RBAppInfo *)info;
@end

@implementation RBAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        UIView *bg = [UIView new];
        bg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
        bg.layer.cornerRadius = 15;
        bg.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        bg.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor;
        self.backgroundView = bg;
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.11];
        self.selectedBackgroundView.layer.cornerRadius = 15;

        _iconView2 = [UIImageView new];
        _iconView2.layer.cornerRadius = 12;
        _iconView2.layer.masksToBounds = YES;
        _iconView2.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        _iconView2.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
        _iconView2.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_iconView2];

        _nameLabel = [UILabel new];
        _nameLabel.textColor = [UIColor whiteColor];
        _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_nameLabel];

        _bidLabel = [UILabel new];
        _bidLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.40];
        _bidLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        _bidLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_bidLabel];

        _stateLabel = [UILabel new];
        _stateLabel.textColor = RBAccent();
        _stateLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        _stateLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_stateLabel];

        _memLabel = [UILabel new];
        _memLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
        _memLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
        _memLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_memLabel];

        // 原来这里是个 UIActivityIndicatorView（转圈）。转圈本身没有「结束」的语义，
        // 用户看到它一直转会以为进程还在跑 —— 换成实心圆点：绿＝在跑，灰＝没在跑。
        _dot = [UIView new];
        _dot.layer.cornerRadius = 3.5;
        _dot.backgroundColor = RBAccent();
        [self.contentView addSubview:_dot];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat w = self.contentView.bounds.size.width;
    _iconView2.frame = CGRectMake(16, (h - 46) / 2.0, 46, 46);
    CGFloat tx = CGRectGetMaxX(_iconView2.frame) + 13;
    CGFloat stateW = 104;
    CGFloat textW = MAX(40, w - tx - stateW - 30);
    _nameLabel.frame = CGRectMake(tx, h / 2.0 - 20, textW, 21);
    _bidLabel.frame  = CGRectMake(tx, h / 2.0 + 1, textW, 16);
    _stateLabel.frame = CGRectMake(w - stateW - 16, h / 2.0 - 20, stateW, 18);
    _memLabel.frame   = CGRectMake(w - stateW - 16, h / 2.0 + 1, stateW, 16);
    _dot.frame = CGRectMake(w - stateW - 27, h / 2.0 - 14.5, 7, 7);
}

- (void)bind:(RBAppInfo *)info {
    self.nameLabel.text = info.name;
    self.bidLabel.text = info.bundleID;
    self.iconView2.image = info.icon ?: [UIImage systemImageNamed:@"app.dashed"];

    // 标签最多显示两个，其余折成「+N」—— 四个标签挤在一行会互相顶掉
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    if (info.locked)       [tags addObject:@"已锁定"];
    // 真后台要分三态。配置里勾了不等于运行时挂上了，挂上断言也不等于拿到了场景：
    //   · 场景   → 真正不被挂起，显示「真后台」
    //   · 仅断言 → 进程保住但系统仍可能挂起它，显示「仅保活」
    //   · 都没挂 → 多半是 App 没在运行，显示「待挂载」
    // 原来三种情况都写「真后台」，等于把降级说成生效。
    if (info.hasBackstage) {
        if (info.backstageLevel == 2)      [tags addObject:@"真后台"];
        else if (info.backstageLevel == 1) [tags addObject:@"仅保活"];
        else                               [tags addObject:@"待挂载"];
    }
    if (info.hasSuicide)   [tags addObject:@"退出即杀"];
    if (info.hasAutoStart) [tags addObject:@"自启"];

    NSString *state = nil;
    if (tags.count == 0) {
        if (info.isRunning) {
            // 系统 App 同样在运行，但加速永远不会碰它们。原来这里也写「运行中」，
            // 用户自然会问「为什么运行中却不清理」——直接标「系统」。
            state = info.isSystem ? @"系统" : @"运行中";
        } else {
            state = @"未运行";
        }
    } else if (tags.count <= 2) {
        state = [tags componentsJoinedByString:@" · "];
    } else {
        state = [NSString stringWithFormat:@"%@ +%lu", tags[0], (unsigned long)(tags.count - 1)];
    }
    self.stateLabel.text = state;

    // 第二行：真实占用。读不到的按经验值显示并加「~」，别让用户以为是精确数字。
    if (info.isRunning && info.memMB > 0) {
        self.memLabel.text = [NSString stringWithFormat:@"%@%@",
                              info.memKnown ? @"" : @"~", RBHumanMB(info.memMB)];
    } else {
        self.memLabel.text = info.isRunning ? @"—" : @"";
    }

    // 仅保活是降级：进程不会被回收，但系统仍可能把它挂起。用告警色区分，
    // 不能和真正拿到场景的「真后台」同一个绿。待挂载则压成灰色 —— 那是配置开了没生效。
    BOOL degraded = (info.hasBackstage && info.backstageLevel == 1);
    BOOL pending  = (info.hasBackstage && info.backstageLevel == 0);
    UIColor *onColor = info.locked ? RBLock()
                     : degraded    ? RBWarn()
                     : pending     ? [UIColor colorWithWhite:1 alpha:0.45]
                                   : RBAccent();
    self.dot.hidden = !info.isRunning;
    self.dot.backgroundColor = onColor;
    if (tags.count) {
        self.stateLabel.textColor = onColor;
    } else if (info.isRunning && info.isSystem) {
        self.stateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    } else {
        self.stateLabel.textColor = info.isRunning ? [UIColor colorWithWhite:1 alpha:0.72]
                                                   : [UIColor colorWithWhite:1 alpha:0.30];
    }
    // 动不了的 App 内存数字也压暗，视觉上区分「可清理」与「不会动」
    self.memLabel.textColor = (!info.isRunning)         ? [UIColor clearColor]
                            : (info.boostable ? [UIColor colorWithWhite:1 alpha:0.50]
                                              : [UIColor colorWithWhite:1 alpha:0.26]);
}

@end

#pragma mark - VC

@interface RBRootVC () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UIButton *boostButton;
@property (nonatomic, strong) CAGradientLayer *boostGradient;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *memLabel;
/// 顶部内存卡片
@property (nonatomic, strong) UIView *memCard;
@property (nonatomic, strong) UILabel *usedValueLabel;
@property (nonatomic, strong) UILabel *freeValueLabel;
@property (nonatomic, strong) UILabel *cleanValueLabel;
@property (nonatomic, strong) UIView *memBar;
@property (nonatomic, strong) UIView *memBarFill;
@property (nonatomic, strong) NSLayoutConstraint *memFillWidth;

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
/// 「可清理」里含有估值成分（读不到 rusage 的进程按经验值算），显示时加 ≈
@property (nonatomic, assign) BOOL estimateApprox;
@property (nonatomic, assign) BOOL hasMemory;
@property (nonatomic, assign) double memRatio;
@property (nonatomic, assign) NSUInteger lockCount;

/// 每次 reload 领一个号。后台线程回来时如果号已经过时（期间又发起了新的 reload），
/// 就把这份结果丢掉 —— 否则加速前发起的那次慢枚举会把加速后的状态覆盖回去，
/// 表现就是「刚加速完，列表又全变成运行中」。
@property (nonatomic, assign) NSUInteger reloadSeq;
@property (nonatomic, assign) NSUInteger appliedSeq;

- (void)buildSeg;
- (void)buildMemCard;
- (void)buildTable;
- (void)buildBoost;
- (void)buildSearch;
- (void)reload;
- (void)applyFilter;
- (void)updateMemoryLabel;
- (void)layoutMemBar;
- (void)updateHintForTab;
- (void)segChanged;
- (void)appDidBecomeActive;
- (void)toggleBackstage:(RBAppInfo *)info;
- (void)toggleLock:(RBAppInfo *)info;
- (void)enableAllRunning;
- (void)tapBoost;
- (void)doBoostWithCandidates:(NSArray *)cands;
- (void)applyKilledIDs:(NSArray *)ids;
- (void)toast:(NSString *)s;
- (void)presentAlert:(UIAlertController *)ac;
- (void)reloadAfterDelay;
- (void)boostPressDown;
- (void)boostPressUp;
- (void)setBoostBusy:(BOOL)busy title:(NSString *)title;
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

    [self buildMemCard];
    [self buildSeg];
    [self buildTable];
    [self buildBoost];
    [self buildSearch];
    [self updateHintForTab];

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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // 渐变层与阴影路径不会自己跟着 Auto Layout 走，必须在布局后手动同步，
    // 否则旋转 / 首次出现时按钮上半截是空的。
    if (self.boostGradient) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.boostGradient.frame = self.boostButton.bounds;
        self.boostButton.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:self.boostButton.bounds cornerRadius:18].CGPath;
        [CATransaction commit];
    }
    [self layoutMemBar];
}

- (void)layoutMemBar {
    CGFloat w = self.memBar.bounds.size.width;
    if (w <= 0) return;
    self.memFillWidth.constant = MAX(0, MIN(1.0, self.memRatio)) * w;
}

- (void)appDidBecomeActive {
    if (!self.safeMode) [self reload];
}

#pragma mark 布局

- (void)buildMemCard {
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.075].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    self.memCard = card;

    NSArray<NSString *> *titles = @[ @"已用", @"可用", @"可清理" ];
    NSArray<UIColor *> *colors = @[ [UIColor colorWithWhite:1 alpha:0.95], RBAccent(), RBLock() ];
    NSMutableArray<UILabel *> *vals = [NSMutableArray array];
    NSMutableArray<UIStackView *> *cols = [NSMutableArray array];

    for (int i = 0; i < 3; i++) {
        UILabel *t = [UILabel new];
        t.text = titles[i];
        t.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        t.textColor = [UIColor colorWithWhite:1 alpha:0.42];
        t.textAlignment = NSTextAlignmentCenter;

        UILabel *v = [UILabel new];
        v.text = @"—";
        v.font = [UIFont monospacedDigitSystemFontOfSize:19 weight:UIFontWeightSemibold];
        v.textColor = colors[i];
        v.textAlignment = NSTextAlignmentCenter;
        v.adjustsFontSizeToFitWidth = YES;
        v.minimumScaleFactor = 0.7;
        [vals addObject:v];

        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[t, v]];
        col.axis = UILayoutConstraintAxisVertical;
        col.alignment = UIStackViewAlignmentFill;
        col.spacing = 1;
        [cols addObject:col];
    }
    self.usedValueLabel  = vals[0];
    self.freeValueLabel  = vals[1];
    self.cleanValueLabel = vals[2];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:cols];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:row];

    // 一条细进度条：已用占比。比纯数字更能一眼看出还剩多少。
    UIView *bar = [UIView new];
    bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    bar.layer.cornerRadius = 2.5;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:bar];
    self.memBar = bar;

    UIView *fill = [UIView new];
    fill.backgroundColor = RBAccent();
    fill.layer.cornerRadius = 2.5;
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:fill];
    self.memBarFill = fill;
    self.memFillWidth = [fill.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [fill.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        self.memFillWidth,
    ]];

    UILabel *note = [UILabel new];
    note.text = @"";
    note.font = [UIFont systemFontOfSize:11.5];
    note.textColor = [UIColor colorWithWhite:1 alpha:0.40];
    note.numberOfLines = 2;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:note];
    self.memLabel = note;

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:6],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-6],

        [bar.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:10],
        [bar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [bar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [bar.heightAnchor constraintEqualToConstant:5],

        [note.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:7],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [note.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11],
    ]];
}

- (void)buildSeg {
    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"运行", @"保活", @"自启", @"锁定"]];
    self.seg.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        self.seg.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.18];
    }
    self.seg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    [self.seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55],
                                        NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium] }
                             forState:UIControlStateNormal];
    [self.seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor whiteColor],
                                        NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold] }
                             forState:UIControlStateSelected];
    [self.seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    self.seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.seg];
    [NSLayoutConstraint activateConstraints:@[
        [self.seg.topAnchor constraintEqualToAnchor:self.memCard.bottomAnchor constant:10],
        [self.seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.seg.heightAnchor constraintEqualToConstant:33],
    ]];
}

- (void)buildTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 72;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.contentInset = UIEdgeInsetsMake(4, 0, 104, 0);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[RBAppCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
}

- (void)buildBoost {
    UIView *bar = [UIView new];
    bar.backgroundColor = [UIColor colorWithWhite:0.045 alpha:0.97];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UIView *hair = [UIView new];
    hair.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    hair.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:hair];

    self.boostButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.boostButton setTitle:@"一键加速" forState:UIControlStateNormal];
    [self.boostButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.boostButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.62] forState:UIControlStateDisabled];
    self.boostButton.titleLabel.font = [UIFont systemFontOfSize:17.5 weight:UIFontWeightBold];
    self.boostButton.layer.cornerRadius = 18;
    // 渐变放在子 layer 里、自己裁圆角，外层就能保留外发光
    // （masksToBounds = YES 会把 shadow 一起裁掉，所以不能靠它裁背景图）
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[ (id)[UIColor colorWithRed:0.20 green:0.84 blue:0.60 alpha:1].CGColor,
                  (id)[UIColor colorWithRed:0.08 green:0.64 blue:0.49 alpha:1].CGColor ];
    g.startPoint = CGPointMake(0.5, 0.0);
    g.endPoint   = CGPointMake(0.5, 1.0);
    g.cornerRadius = 18;
    [self.boostButton.layer insertSublayer:g atIndex:0];
    self.boostGradient = g;
    self.boostButton.layer.shadowColor = [UIColor colorWithRed:0.10 green:0.80 blue:0.55 alpha:0.40].CGColor;
    self.boostButton.layer.shadowOpacity = 1;
    self.boostButton.layer.shadowRadius = 14;
    self.boostButton.layer.shadowOffset = CGSizeMake(0, 5);
    [self.boostButton addTarget:self action:@selector(tapBoost) forControlEvents:UIControlEventTouchUpInside];
    [self.boostButton addTarget:self action:@selector(boostPressDown) forControlEvents:UIControlEventTouchDown];
    [self.boostButton addTarget:self action:@selector(boostPressUp)
               forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    self.boostButton.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.boostButton];

    UILabel *hint = [UILabel new];
    hint.text = @"";
    hint.font = [UIFont systemFontOfSize:10.5];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.32];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.adjustsFontSizeToFitWidth = YES;
    hint.minimumScaleFactor = 0.85;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:hint];
    self.hintLabel = hint;

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [hair.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [hair.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [hair.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [hair.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],

        [self.boostButton.topAnchor constraintEqualToAnchor:bar.topAnchor constant:10],
        [self.boostButton.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [self.boostButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [self.boostButton.heightAnchor constraintEqualToConstant:52],

        [hint.topAnchor constraintEqualToAnchor:self.boostButton.bottomAnchor constant:7],
        [hint.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [hint.bottomAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.bottomAnchor constant:-6],

        [self.tableView.topAnchor constraintEqualToAnchor:self.seg.bottomAnchor constant:6],
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
    NSUInteger seq = ++self.reloadSeq;

    // 保护等级要在主线程取快照：RBBackstage 的字典是主线程写的，
    // 后台线程直接读会和挂载/撤销撞在一起。快照很小（几十个 key），代价可以忽略。
    NSDictionary<NSString *, NSNumber *> *levels = [[RBBackstage shared] levelSnapshot];

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
            i.backstageLevel = levels[i.bundleID].integerValue;
            i.hasAutoStart = [store.autoStartIDs containsObject:i.bundleID];
            i.hasSuicide = [store.suicideIDs containsObject:i.bundleID];
            i.locked = [store.lockIDs containsObject:i.bundleID];
            i.boostable = i.isRunning && [RBBooster isBoostableBundle:i.bundleID protect:protect];

            if (i.isRunning) {
                NSDictionary *u = [RBBooster usageForPid:i.pid];
                i.memMB = [u[@"mb"] doubleValue];
                i.memKnown = ![u[@"estimated"] boolValue];
            } else {
                i.memMB = 0;
                i.memKnown = NO;
            }
        }

        // 内存与「可清理」只在这里算一次，别在每次刷新界面时重算
        double used = [RBProcesses usedMemoryMB];
        double freeMB = [RBProcesses freeMemoryMB];
        BOOL hasMemory = (used + freeMB) > 1.0;
        double est = 0;
        BOOL estApprox = NO;
        for (NSDictionary *d in [RBBooster candidatesProtecting:protect]) {
            est += [d[@"mb"] doubleValue];
            if ([d[@"estimated"] boolValue]) estApprox = YES;
        }

        NSUInteger lockCount = store.lockIDs.count;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;

            // 结果过期就整份丢掉：期间已经发起了更新的 reload（或加速刚就地改过状态），
            // 这份慢枚举拿到的是加速之前的进程表，写进去就把界面拉回旧状态。
            if (seq < self.appliedSeq) {
                if (self.pendingReload) { self.pendingReload = NO; [self reload]; }
                return;
            }
            self.appliedSeq = seq;

            self.allApps = [apps copy];
            self.usedMB = used;
            self.freeMB = freeMB;
            self.estimateMB = est;
            self.estimateApprox = estApprox;
            self.hasMemory = hasMemory;
            self.lockCount = lockCount;
            if (apps.count > 0) self.safeMode = NO;    // 枚举成功就退出安全模式
            [self applyFilter];
            [self updateMemoryLabel];

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
        self.usedValueLabel.text  = @"—";
        self.freeValueLabel.text  = @"—";
        self.cleanValueLabel.text = @"—";
        self.memRatio = 0;
        self.memLabel.text = self.safeMode
            ? @"上次启动异常，已进入安全模式 · 点右上「刷新」重试"
            : @"内存信息读取失败";
        [self layoutMemBar];
        return;
    }

    self.usedValueLabel.text  = RBHumanMB(self.usedMB);
    self.freeValueLabel.text  = RBHumanMB(self.freeMB);
    self.cleanValueLabel.text = self.estimateMB > 0.5
        ? [NSString stringWithFormat:@"%@%@", self.estimateApprox ? @"≈" : @"",
           RBHumanMB(self.estimateMB)]
        : @"0";

    double total = self.usedMB + self.freeMB;
    self.memRatio = total > 1.0 ? (self.usedMB / total) : 0;

    NSMutableString *note = [NSMutableString string];
    [note appendFormat:@"已用 %.0f%% · 共 %@", self.memRatio * 100.0, RBHumanMB(total)];
    if (self.lockCount > 0) {
        [note appendFormat:@" · 已锁定 %lu 个", (unsigned long)self.lockCount];
    }
    self.memLabel.text = note;
    [self layoutMemBar];
}

/// 加速完成后立刻把「已确认结束」的 App 就地标记成未运行。
/// 不等后台重新枚举 —— 一次完整枚举要扫全部安装包并解图标，几秒钟内界面还是旧状态，
/// 用户就会觉得「加速了但它还在运行」。真实状态随后由 reload 校正。
- (void)applyKilledIDs:(NSArray *)ids {
    if (ids.count == 0) return;
    NSSet *set = [NSSet setWithArray:ids];
    for (RBAppInfo *i in self.allApps) {
        if ([set containsObject:i.bundleID]) {
            i.isRunning = NO;
            i.pid = 0;
            i.memMB = 0;
            i.memKnown = NO;
            i.boostable = NO;
        }
    }
    // 让所有在飞的 reload 作废，避免它们带着杀之前的数据覆盖回来
    self.appliedSeq = ++self.reloadSeq;
    [self applyFilter];
    [self updateMemoryLabel];
}

- (void)reloadAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reload]; });
}

- (void)segChanged {
    self.tab = self.seg.selectedSegmentIndex;
    [self updateHintForTab];
    [self applyFilter];
}

/// 底部的说明文字跟着当前分段走。自启和保活是最容易被混为一谈的两个概念，
/// 在哪一页就地把区别写出来，比藏在文档里有用。
- (void)updateHintForTab {
    NSArray<NSString *> *lines = @[
        @"点一下看详情 · 右滑可锁定 / 自启 / 杀后台",
        @"绿点 = 有进程在跑 · 一键加速会结束未锁定的",
        @"真后台 = 不被挂起（绿）· 仅保活 = 不被回收但仍会被挂起（橙）",
        @"自启 = 打开本工具时按名单重新拉起并保活",
        @"锁定 = 加速和退出清理都不碰，优先级最高",
    ];
    if (self.tab >= 0 && (NSUInteger)self.tab < lines.count) {
        self.hintLabel.text = lines[self.tab];
    }
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
        if (info.hasAutoStart) {
            [s.autoStartIDs removeObject:info.bundleID];
            [self toast:[NSString stringWithFormat:@"%@ 已取消自启", info.name]];
        } else {
            [s.autoStartIDs addObject:info.bundleID];
            [self toast:[NSString stringWithFormat:@"%@ 已加入自启 · 下次打开本工具会自动拉起", info.name]];
        }
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
    if (info.isRunning && info.isSystem) {
        // 系统 App 放一条明确说明，而不是让用户点了没反应
        UIAlertAction *a = [UIAlertAction actionWithTitle:@"系统 App，不在清理范围"
                                                    style:UIAlertActionStyleDefault handler:nil];
        a.enabled = NO;
        [ac addAction:a];
    } else if (info.isRunning) {
        [ac addAction:[UIAlertAction actionWithTitle:@"杀后台" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            if (info.locked) {
                [self toast:@"已锁定，先取消锁定再杀"];
                return;
            }
            // 先撤掉这个 App 的保活再杀。留着 scene 直接 kill，FrontBoard 会立刻把它
            // 重新拉到后台 —— 用户看到的就是「杀了还在跑」。
            [[RBBackstage shared] disableForBundle:info.bundleID];
            BOOL ok = [RBProcesses killApp:info.bundleID pid:info.pid];
            if (ok) {
                [self applyKilledIDs:@[info.bundleID]];
                [self toast:[NSString stringWithFormat:@"%@ 已结束", info.name]];
            } else {
                [self toast:[NSString stringWithFormat:@"%@ 没能结束（可能被系统托管）", info.name]];
                [self reloadAfterDelay];
            }
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
        // 挂上不等于挂到场景。只拿到断言时如实说 —— 原来这里一律报「已进入真后台」，
        // 用户在降级状态下会以为后台真的保住了。
        NSInteger lv = [[RBBackstage shared] levelForBundle:info.bundleID];
        if (lv == 2) {
            [self toast:[NSString stringWithFormat:@"%@ 已进入真后台", info.name]];
        } else {
            [self toast:[NSString stringWithFormat:@"%@ 仅保活：进程不会被回收，但仍可能被挂起", info.name]];
        }
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

    NSUInteger ok = 0, scene = 0;
    RBStore *s = [RBStore shared];
    for (RBAppInfo *i in targets) {
        if ([[RBBackstage shared] enableForBundle:i.bundleID pid:i.pid error:NULL]) {
            [s.backstageIDs addObject:i.bundleID];
            ok++;
            if ([[RBBackstage shared] levelForBundle:i.bundleID] == 2) scene++;
        }
    }
    [s save];
    // 把「场景」和「仅断言」分开报数。只报成功数会让人以为全部都在真跑。
    if (ok == 0) {
        [self toast:@"全部失败，检查日志"];
    } else if (scene == ok) {
        [self toast:[NSString stringWithFormat:@"已开启 %lu/%lu 个，全部拿到真后台场景",
                    (unsigned long)ok, (unsigned long)targets.count]];
    } else {
        [self toast:[NSString stringWithFormat:@"已开启 %lu/%lu 个，其中 %lu 个只拿到保活断言",
                    (unsigned long)ok, (unsigned long)targets.count, (unsigned long)(ok - scene)]];
    }
    [self reload];
}

- (void)setBoostBusy:(BOOL)busy title:(NSString *)title {
    self.boostBusy = busy;
    self.boostButton.enabled = !busy;
    self.boostButton.alpha = busy ? 0.72 : 1.0;
    [self.boostButton setTitle:title forState:UIControlStateNormal];
}

- (void)boostPressDown {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.boostButton.transform = CGAffineTransformMakeScale(0.975, 0.975);
    } completion:nil];
}

- (void)boostPressUp {
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.58 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.boostButton.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (NSDictionary<NSString *, NSString *> *)nameMap {
    NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionary];
    for (RBAppInfo *i in self.allApps) {
        if (i.bundleID.length) m[i.bundleID] = i.name ?: i.bundleID;
    }
    return m;
}

- (void)tapBoost {
    if (self.boostBusy) return;
    [self setBoostBusy:YES title:@"正在统计…"];

    NSSet *protect = [[RBStore shared] allProtectedIDs];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *cands = [RBBooster candidatesProtecting:protect];
        // 「运行中但不会碰」的完整清单（含系统 / 锁定 / 真后台）。
        // 用户问的「为什么只清两个」就靠它回答：把没清的也列出来，别让他自己数。
        NSArray *held = [RBBooster protectedRunningProtecting:protect];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBoostBusy:NO title:@"一键加速"];

            // 锁定项的名字要换成 App 显示名，bundleID 对普通用户没意义
            NSDictionary *nameMap = [self nameMap];

            // 按原因分组。系统进程数量多、名字对用户也没意义，只报个数。
            NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups = [NSMutableDictionary dictionary];
            for (NSDictionary *d in held) {
                NSString *why = d[@"reason"] ?: @"其他";
                NSString *bid = d[@"bundleID"];
                if (!groups[why]) groups[why] = [NSMutableArray array];
                [groups[why] addObject:nameMap[bid] ?: bid];
            }

            NSMutableString *holdLine = [NSMutableString string];
            for (NSString *why in @[@"锁定", @"真后台"]) {
                NSArray *names = groups[why];
                if (names.count == 0) continue;
                NSUInteger show = MIN(names.count, 4u);
                [holdLine appendFormat:@"· %@ %lu 个：%@%@\n", why, (unsigned long)names.count,
                 [[names subarrayWithRange:NSMakeRange(0, show)] componentsJoinedByString:@"、"],
                 names.count > show ? @"…" : @""];
            }
            if (groups[@"系统"].count > 0) {
                [holdLine appendFormat:@"· 系统 %lu 个（不清理）\n", (unsigned long)groups[@"系统"].count];
            }
            if (groups[@"自身"].count > 0) {
                [holdLine appendFormat:@"· 本 App 自身 %lu 个\n", (unsigned long)groups[@"自身"].count];
            }

            if (cands.count == 0) {
                // 现在没有内存门槛了，候选为空只可能是「跑着的都受保护」。
                NSString *msg = nil;
                if (holdLine.length) {
                    msg = [NSString stringWithFormat:
                           @"后台在跑的都受保护，没有可清理的：\n\n%@", holdLine];
                } else {
                    msg = @"当前没有第三方 App 在后台运行。\n系统 App 不在清理范围内。";
                }
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"不需要加速"
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
                [list appendFormat:@"… 另有 %lu 个\n", (unsigned long)(cands.count - shown)];
            }

            NSString *msg = [NSString stringWithFormat:@"预计释放约 %@\n\n%@",
                             RBHumanMB(est), list];
            if (holdLine.length) {
                msg = [msg stringByAppendingFormat:@"\n保留不动：\n%@", holdLine];
            }

            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:[NSString stringWithFormat:@"将结束 %lu 个后台进程", (unsigned long)cands.count]
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"开始加速" style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) { [self doBoostWithCandidates:cands]; }]];
            [self presentAlert:ac];
        });
    });
}

- (void)doBoostWithCandidates:(NSArray *)cands {
    [self setBoostBusy:YES title:@"正在加速…"];

    NSSet *protect = [[RBStore shared] allProtectedIDs];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *r = [RBBooster boostProtecting:protect];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBoostBusy:NO title:@"一键加速"];

            NSUInteger killed = [r[@"killed"] unsignedIntegerValue];
            NSUInteger failed = [r[@"failed"] unsignedIntegerValue];
            NSUInteger relau  = [r[@"relaunched"] unsignedIntegerValue];
            NSUInteger rounds = [r[@"rounds"] unsignedIntegerValue];
            double freed    = [r[@"freedMB"] doubleValue];
            double byKill   = [r[@"freedByKillMB"] doubleValue];
            double afterUsed = [r[@"afterUsedMB"] doubleValue];
            double afterFree = [r[@"afterMB"] doubleValue];

            // 实测下降量可能为 0（系统还没回收完页面），这时退回「被杀进程占用之和」，
            // 但文案上标成「≈」，不假装是实测值。
            NSString *freedText;
            if (freed >= 1.0) {
                freedText = [NSString stringWithFormat:@"已用内存下降 %@", RBHumanMB(freed)];
            } else if (byKill >= 1.0) {
                freedText = [NSString stringWithFormat:@"结束进程共占 ≈%@（系统稍后回收）", RBHumanMB(byKill)];
            } else {
                freedText = @"已用内存没有明显变化";
            }

            NSMutableString *msg = [NSMutableString string];
            [msg appendFormat:@"结束 %lu 个后台进程", (unsigned long)killed];
            if (relau > 0) {
                [msg appendFormat:@"（其中 %lu 个被系统重新拉起，已清 %lu 轮）",
                 (unsigned long)relau, (unsigned long)rounds];
            }
            [msg appendFormat:@"\n%@\n现在已用 %@ · 可用 %@", freedText,
             RBHumanMB(afterUsed), RBHumanMB(afterFree)];

            if (failed > 0) {
                [msg appendFormat:@"\n\n有 %lu 个结束不了（系统拒绝或已被托管），已跳过。", (unsigned long)failed];
            }

            NSUInteger lockedSkipped = [r[@"lockedSkipped"] unsignedIntegerValue];
            if (lockedSkipped > 0) {
                [msg appendFormat:@"\n\n🔒 锁定保留 %lu 个（约 %@），没有被碰。",
                 (unsigned long)lockedSkipped, RBHumanMB([r[@"lockedKeptMB"] doubleValue])];
            }

            NSString *title = killed > 0 ? @"加速完成" : @"没能结束任何进程";

            // 先就地把状态改掉再弹窗：用户关掉弹窗看到的列表必须已经是新的
            [self applyKilledIDs:r[@"killedIDs"]];

            UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentAlert:ac];

            // 再让后台重新枚举一遍，把「被重新拉起」的真实情况校正回来
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
