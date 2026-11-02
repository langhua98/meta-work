# META CRAFT V2.1 代码审阅（Claude）

> 审的是 `langhua98/meta-work` main 分支（提交 `0315eca`）的 `index.html`，683,368 字节，和 `minecraft-v2.1-jitter-fix.html` 完全相同。
> 写给 Meta AI。只提意见，没有改 `index.html`。

## 先说一句：关于行号

`index.html` 不是源码，是**打包后的产物**：React 18 + Three.js r160 + Tailwind 全部压成一个 `<script type="module">`，游戏代码挤在**第 5254 行**的一整行里（约 7.4 万字符），变量名都被压缩过（`z`、`_`、`n`、`b0`……）。所以下面写的是 **「第 5254 行 + 能搜到的关键字」**，再用可读的名字说明。

建议：以后请把**未打包的源码**（比如 `src/App.jsx`）一起放进仓库，审阅、diff、定位都会容易得多。`src/` 现在是空的。

压缩名对照（下面会用到）：

| 压缩名 | 含义 |
|---|---|
| `z` | player（`Group`，相机 `_` 挂在它下面） |
| `_` | camera |
| `M` | velocity |
| `j` | onGround |
| `n` | blockData（`Map`，键 `"x_y_z"`） |
| `a` | chunks（`Map`，键 `"cx,cz"`） |
| `Y0(x,z)` | 地形高度函数 |
| `b0(dt)` | 固定步长的物理更新 |
| `S(t)` | requestAnimationFrame 主循环 |
| `d()` / `k0()` / `G0()` / `y0()` | 射线选方块 / 高亮框 / 挖 / 放 |
| `w6 = 1.62`、`A$ = 0.15`、`fk = 0.2`、`qk = 4` | 眼高、死区、lerp、视距 |

---

## 严重 Bug

### 1. 抖动的真正来源还在：站着不动也会一直上下弹（第 5254 行，搜 `F1+2+w6`）

V2.1 修了相机双写和 delta 限幅，但这不是主要原因。**落地判定本身在不停地把玩家往上弹一格**：

```js
// 现在的代码（还原后）
let feet = z.position.y - w6;
let F1 = Math.floor(feet - 0.1);              // 脚下那块
let Z1 = n.has(`${x}_${F1}_${zz}`) || feet <= n0 + 0.1;
if (feet < n0 || (Z1 && M.y <= 0 && feet < F1 + 2)) {
  z.position.y = Math.max(n0 + w6, F1 + 2 + w6);   // ← 方块顶面是 F1+1，这里写成了 F1+2
  ...
}
```

方块 `F1` 占 `[F1, F1+1]`，顶面是 `F1 + 1`。代码把脚放到 `F1 + 2`，**高出地面整整一格**；下一帧脚下变成空气，开始下落；落到 `F1+1.1` 又被弹回 `F1+2`。

我按这段逻辑模拟了 2 秒（地面高度 30，玩家不动），脚的高度：

```
32.0, 31.92, 31.72, 31.4, 31.99, 31.89, 31.67, 31.32, 31.98, 31.86, 31.61, 31.23, ...
```

**一直在 31.1 到 32 之间约每 0.3 秒弹一次**，这就是用户说的「打开就抖」。另外 `onGround` 在 true/false 之间来回跳，所以 JUMP 按钮有时按了没反应。

修复：

```js
const feet = player.position.y - EYE;          // EYE = 1.62
const below = Math.floor(feet - 0.001);
const solidBelow = blockData.has(key(px, below, pz));
if (velocity.y <= 0 && solidBelow && feet < below + 1 + 0.001) {
  player.position.y = below + 1 + EYE;          // 顶面 = below + 1
  velocity.y = 0;
  onGround = true;
} else {
  onGround = false;
}
```

并且**删掉 `Y0()` 那条地形高度兜底**（见第 3 条）。

### 2. 眼睛高度算了两次，视角在 3.24 格高（搜 `_.position.set(0,w6,0)`）

相机 `_` 是 player 组 `z` 的子物体，并且 `_.position.set(0, w6, 0)`；但物理里又把 `z.position.y` 当作「眼睛」，脚 = `z.y - w6`。结果眼睛实际在脚上方 `1.62 + 1.62 = 3.24` 格，像站在高跷上，也让近处方块看起来很怪。

修复二选一（推荐 A）：

```js
// A：player 的位置 = 脚，相机抬高 1.62
camera.position.set(0, EYE, 0);
const feet = player.position.y;               // 物理全部按脚算
// B：player 的位置 = 眼睛，相机放在 0
camera.position.set(0, 0, 0);
```

顺便：`t.lerp(O0, fk); _.position.lerp(t, fk)` 里 `O0` 和 `t` 都是常量 `(0, 1.62, 0)`，这两行什么都没做，可以删。注释里写的「Camera = player.getObject() only」在代码里并不存在。

### 3. 挖不下去、掉不进洞穴；挖出来的坑会「穿模」（搜 `Y0(z.position.x,z.position.z)+1`）

落地判定用 `n0 = Y0(x, z) + 1`，也就是**按原始地形高度兜底**。挖掉脚下的方块以后，玩家仍然站在空中（原来地面的高度），永远下不去；洞穴、矿石（钻石在 y<10）都去不了。

修复：只用 `blockData` 判断是否站在方块上（第 1 条的代码），彻底删掉 `Y0()` 在物理里的使用。出生点用 `Y0(0,0) + 2` 算一次就行。

### 4. PLACE 永远放草方块，选什么都没用（搜 `let x0=J`）

`useEffect(..., [])` 只在第一次渲染时运行，里面的 `y0()` 读的 `J`（当前选中的方块）**永远是初始值 0**，所以无论选哪个，放出来都是 Grass。

修复：用 ref 同步：

```js
const selectedRef = useRef(0);
useEffect(() => { selectedRef.current = selected; }, [selected]);
// y0() 里
const id = selectedRef.current;
```

### 5. 背包是 0 也能无限放方块（搜 `if(v1[x0]<=0)return v1`）

判断写在 `setState` 的更新函数里，只是「不扣数量」，后面放方块的代码照样执行。和第 4 条一起改：

```js
const inv = inventoryRef.current;              // 同样用 ref 镜像背包
if ((inv[id] ?? 0) <= 0) return;               // 先判断，没有就直接 return
setInventory(v => { const c = [...v]; c[id]--; return c; });
```

### 6. iPhone 横屏时摇杆不见了，手机控制全部失效（搜 `md:hidden`）

手机控制区用了 Tailwind 的 `md:hidden`，桌面按钮用 `hidden md:flex`，`md` = **宽度 ≥ 768px**。iPhone 横屏的 CSS 宽度是 844 / 852 / 932px，**全都 ≥ 768**，所以在你强制横屏之后：

- 摇杆和手机版 BREAK/PLACE/JUMP 被隐藏，显示的是桌面版按钮（没有摇杆，走不了路）；
- 点画布会走 `requestPointerLock()`（`if (window.innerWidth < 768) return` 拦不住）。

修复：按「是不是触屏」判断，不要按宽度：

```js
const isTouch = matchMedia('(pointer: coarse)').matches || 'ontouchstart' in window;
// JSX
{isTouch ? <TouchControls/> : <DesktopControls/>}
// 点击锁鼠标
if (isTouch) return; canvas.requestPointerLock();
```

### 7. 一边走一边转视角不行（多指触控没按 identifier 区分）（搜 `A.touches.length===1`）

- 右半屏看视角只在 `touches.length === 1` 时开始，**左手按着摇杆时，右手再按就不认**；
- 视角和摇杆都读 `touches[0]`，两根手指时会读到对方的手指，视角乱跳；
- 在右边按 BREAK/PLACE/JUMP 也会触发「看视角」，按按钮时画面会晃。

修复：每根手指按 `identifier` 跟踪：

```js
let lookId = null, joyId = null;
window.addEventListener('touchstart', e => {
  for (const t of e.changedTouches) {
    if (t.target.closest('button, .joystick')) continue;   // 按钮和摇杆不算看视角
    if (lookId === null && t.clientX > innerWidth * 0.4) {
      lookId = t.identifier; last = { x: t.clientX, y: t.clientY };
    }
  }
}, { passive: true });
window.addEventListener('touchmove', e => {
  for (const t of e.changedTouches) if (t.identifier === lookId) { /* 转视角 */ }
}, { passive: true });
window.addEventListener('touchend', e => {
  for (const t of e.changedTouches) if (t.identifier === lookId) lookId = null;
});
// 摇杆同理：touchstart 记 joyId = e.changedTouches[0].identifier，move 时找这个 id
```

### 8. 走远再回来，挖掉的方块又长回来了，放的方块变成「隐形墙」（搜 `B.remove(L8),a.delete(U1)`）

卸载区块只删了 mesh，`blockData` 里的数据不删；回来时 `m0()` 重新生成地形，覆盖掉挖掉的格子；玩家放的方块还在 `blockData` 里（有碰撞），但 mesh 没了（看不见）。

修复：把玩家的修改单独存起来，生成区块时套用：

```js
const edits = new Map();            // "x_y_z" -> blockId 或 -1（挖掉）
// 挖：edits.set(k, -1)；放：edits.set(k, id)
// m0() 生成每一格后：
const e = edits.get(k);
if (e === -1) continue;             // 被挖掉的不生成
// 区块生成完，再把 edits 里属于这个区块、id>=0 的方块加进去
// 卸载区块时，同时删掉 blockData 里属于这个区块的键
```

### 9. 白屏 / 变量提升检查：这一版没问题

查了 `BLOCK_IDS`、`E0`、所有常量：常量都在组件外顶部定义（`Mk`、`A$`、`UJ` 等），组件里没有「先用后定义」的 `let/const`，**这一版没有 TDZ 白屏风险**。`BLOCK_IDS` 已经不存在了。

但是 Three.js 和 React 都打包进了文件里，**只要有一个运行时错误就是整页白屏**，没有任何提示。建议加一个兜底：

```html
<script>
window.addEventListener('error', e => {
  document.body.insertAdjacentHTML('beforeend',
    `<pre style="position:fixed;inset:0;z-index:99999;background:#000;color:#f66;padding:12px;white-space:pre-wrap">${e.message}\n${e.filename}:${e.lineno}</pre>`);
});
</script>
```

这样以后用户手机上白屏，截个图就知道是哪一行。

---

## 性能建议

### P1. 高亮框每个物理步都做一次超重的射线检测（最卡的地方）（搜 `c.intersectObject(F1)`）

`k0()` 在 `b0()` 里每个物理步都调用（60 次/秒，掉帧时一帧 2~6 次），`d()` 对周围 **5×5 = 25 个区块里的每一个 InstancedMesh** 做 `raycaster.intersectObject`。Three.js 的 InstancedMesh 射线检测会**逐个实例**测试，一个区块几千个方块，加起来每次十几万次盒子测试。低端机掉帧、发热的主要原因就是这个。

修复：方块世界不用 Three.js 射线，直接在 `blockData` 上走格子（DDA，最多走 6 格）：

```js
function raycastVoxel(origin, dir, maxDist = 6) {
  let x = Math.floor(origin.x), y = Math.floor(origin.y), z = Math.floor(origin.z);
  const sx = Math.sign(dir.x), sy = Math.sign(dir.y), sz = Math.sign(dir.z);
  const inv = v => (v ? Math.abs(1 / v) : Infinity);
  const tdx = inv(dir.x), tdy = inv(dir.y), tdz = inv(dir.z);
  const first = (s, p, c, td) => (s === 0 ? Infinity : (s > 0 ? c + 1 - p : p - c) * td);
  let tx = first(sx, origin.x, x, tdx);
  let ty = first(sy, origin.y, y, tdy);
  let tz = first(sz, origin.z, z, tdz);
  let normal = [0, 0, 0], t = 0;
  while (t <= maxDist) {
    if (blockData.has(`${x}_${y}_${z}`)) return { x, y, z, normal };
    if (tx < ty && tx < tz) { x += sx; t = tx; tx += tdx; normal = [-sx, 0, 0]; }
    else if (ty < tz)       { y += sy; t = ty; ty += tdy; normal = [0, -sy, 0]; }
    else                    { z += sz; t = tz; tz += tdz; normal = [0, 0, -sz]; }
  }
  return null;
}
```

并且高亮框**每帧算一次**（放到 `S()` 里 render 前），不要放在物理步里。

### P2. 每个物理步都 `new Fog(...)`（搜 `B.fog=new JQ`）

一秒 60 个新对象，GC 一回收就卡一下，看起来也像「抖」。改成改值：

```js
scene.fog.color.setHSL(0.6, 0.6, 0.3 + t * 0.3);
scene.fog.density = 0.012 + (1 - t) * 0.01;
```

同理：`z.position.clone()`、僵尸里的 `new Vector3()`、`d()` 里的 `new Vector2(0,0)` 都在每步分配，改成复用模块级的临时变量。

### P3. 内存泄漏：卸载区块、放方块都没有 `dispose()`

- 卸载区块（搜 `B.remove(L8)`）：只 `remove`，没释放 InstancedMesh 的 GPU 缓冲；
- 放方块（搜 `a0.remove(S0),(S0=c1)`）：**每放一个方块就新建一个大一号的 InstancedMesh**，旧的直接丢掉，也不释放；
- `blockData` 永远只增不减（第 8 条）。

```js
// 卸载
chunk.children.forEach(m => m.dispose());   // InstancedMesh.dispose()，几何体和材质是共享的，别 dispose 它们
scene.remove(chunk);
// 放方块：一开始就多留空间，用 count 控制显示数量
const mesh = new THREE.InstancedMesh(geo, mat, capacity + 256);
mesh.count = used;
```

另外，放方块新建的 InstancedMesh 没有设置 `castShadow / receiveShadow`，放出来的方块没有阴影。

### P4. 区块生成一次就卡一下

`m0()` 一次生成一个区块（16×16×~30），要建几千个 `Vector3` 和字符串键，在主线程同步做，走路时每进入新区块就卡一帧。

- 短期：键改成数字 `((x * 4096 + y) * 4096 + z)` 或每个区块一个 `Uint8Array(16*16*64)`，比字符串 Map 快很多也省内存；
- 只放「露在外面」的方块（六个面里至少一个邻居是空气），实例数能少 70% 以上；
- 长期：地形生成放进 **Web Worker**，主线程只收 `Float32Array` 矩阵。值得做，但排在上面几条之后。

### P5. 树太多（搜 `Lk(x0,g0)>0.75`）

`Lk()` 先把坐标除以 10 再取整，所以**同一个 10×10 格子里的值都一样**；一旦超过 0.75，这 100 列**每一列都种一棵树**，一片就是 100 棵树、6000 多片树叶挤在一起，又难看又卡。

```js
// 用逐格哈希，并且控制密度
const h = hash2(x0, g0);            // 不要先 *0.1 取整
if (biome === 0 && h > 0.985 && N1 > 24 && N1 < 36) { /* 种树 */ }
```

### P6. 低端机配置

- 视距 4（菱形，约 41 个区块）+ `antialias: true` + 1024 阴影贴图 + 所有方块都投射阴影，对低端手机太重。建议手机上：`antialias: false`、`pixelRatio` 上限 1.5、阴影关掉或只给玩家附近的区块开，视距 3；
- 可以加一个「流畅 / 高画质」切换，或者按 FPS 自动降级（连续 3 秒低于 40 帧就降一档）。

### P7. 固定步长：做法对，但缺插值

`S()` 里的 accumulator（1/60，maxDelta 0.1）写法是对的。但渲染时没有在两个物理状态之间插值，屏幕刷新率不是正好 60Hz 时（iPhone 低电量模式 30Hz、ProMotion 120Hz、掉帧时）会一帧走 0 步、一帧走 2 步，轻微顿挫。修完第 1 条以后如果还觉得不顺，再加：

```js
const alpha = acc / STEP;
renderPos.lerpVectors(prevPos, player.position, alpha);
```

### P8. 事件监听没全部清理

`useEffect` 的清理函数漏掉了摇杆的 `touchstart/touchmove/touchend/mousedown`、`window` 上的匿名 `mousemove/mouseup`，以及画布的 `click`。现在生产环境只挂载一次问题不大，但开发模式 StrictMode 会挂载两次，监听器就重复了。

---

## 其他小问题

- **桌面空格不能跳**：`keydown` 里记录了 `Space`，但 `b0()` 从来没读它。加：`if (keys.Space && onGround) velocity.y = JUMP;`
- **桌面鼠标不能挖 / 放**：按钮上写着 LMB/RMB，但没有监听鼠标左右键。
- **动物和僵尸只在出生点附近生成**，走远就再也看不到了；建议按区块生成、卸载。
- **说明文字和代码对不上**：文案写了 Simplex Noise、AO（环境光遮蔽）、「camera = player.getObject()」，代码里都没有（地形是 sin + 哈希，没有 AO）。要么实现，要么改文案。
- `<title>` 还是 `React Artifact`，建议改成 `META CRAFT v2.1.0`。
- 竖屏遮罩：只是覆盖了一层，游戏循环还在跑（耗电）；遮罩显示时可以暂停循环。`screen.orientation.lock` 在 iOS Safari 不支持、安卓也只有全屏时才生效，现在用 `.catch` 吞掉了，没问题。

## 版本号

左上角显示 `META CRAFT v2.1.0 JITTER FIX` 和 `BUILD FOR langhua98/meta-work` ✓，底部也有。版本号是常量 `Mk = "v2.1.0"`，以后每次改这一个地方就行。建议同时在 HTML 注释或 `<meta name="version">` 里写一份，不打开页面也能看到版本。

---

## 下一版 V2.2 建议

**先修（必须）**：严重 Bug 1~8 + 性能 P1~P3。其中 **1、2、3 一起改**（物理统一按「脚的位置 + blockData」来算），抖动就会消失；**6、7** 修完手机才真正能玩。

**再加功能（按性价比排序）**：

1. **存档**：把 `edits`（第 8 条）存进 `localStorage`，刷新不丢；加「新世界 / 种子」。
2. **生存基础**：血量、摔落伤害、僵尸碰到掉血、夜晚僵尸变多、死亡重生。
3. **真正的挖掘**：按住 BREAK 有挖掘进度（不同方块不同时间），配合裂纹动画。
4. **合成表**：现在「⚒」只是选方块，做真正的配方（木头 → 木板，圆石 → 熔炉等）。
5. **水和发光**：简单的水方块（半透明、不可站立）、火把（点光源，晚上有用）。
6. **性能档位**：设置面板里切视距、阴影、画质（见 P6）。
7. **音效和手感**：挖、放、走路的声音；放方块时手机震动 `navigator.vibrate(10)`。

**工程上**：源码放 `src/`，用 Vite 打包，`index.html` 由构建生成；仓库加一个 GitHub Actions 跑 `vite build`，这样每次改动都有 diff，审阅也能精确到行号。

-- Claude
