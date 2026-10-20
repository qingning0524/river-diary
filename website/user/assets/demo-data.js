/* Synthetic memories for the console preview.
 *
 * Every person, place and sentence here is invented for design review.  The
 * preview never reads the repository's data/ snapshots and never calls a model.
 */

import { MIRROR_FORMAT, MIRROR_VERSION, addDays, dateKey } from './memory-core.js?v=20261020-cloud';

export const DEMO_PERSONA = {
  name: '林岸',
  email: 'lin.an@example.com',
  since: '2021 年 3 月',
  line: '把日子过成一条可以回头的河。',
};

const COLLECTIONS = [
  {
    id: 'c1', title: '搬到杭州的第一年', tone: 'sea',
    description: '从上海到杭州，从两个人住到一个人住。那一年留下的，多半是路和窗。',
    entryIds: ['d21', 'd23', 'd28', 'd30', 'd31', 'd32', 'd45', 'd49'],
  },
  {
    id: 'c2', title: '跑步这件小事', tone: 'moss',
    description: '从三公里到十公里，不为了证明什么，只是想让早晨有一个去处。',
    entryIds: ['d09', 'd24', 'd35', 'd40', 'd47'],
  },
  {
    id: 'c3', title: '厨房里的灯', tone: 'clay',
    description: '番茄、牛腩、薄荷和外婆的红烧肉。灯亮着的时候，房子才像家。',
    entryIds: ['d04', 'd14', 'd16', 'd25', 'd33', 'd38', 'd46'],
  },
  {
    id: 'c4', title: '独居的第三个冬天', tone: 'dusk',
    description: '电热毯、窗上的雾和一个人的除夕。不是难过，只是很安静。',
    entryIds: ['d10', 'd18', 'd29'],
  },
  {
    id: 'c5', title: '和父亲的电话', tone: 'sand',
    description: '他不太会说话，后来学会了发照片。语音总是很长，开头都是「没什么事」。',
    entryIds: ['d11', 'd15', 'd26', 'd36', 'd43'],
  },
  {
    id: 'c6', title: '读过的书与走过的路', tone: 'rose',
    description: '书店、车站、一本讲河流的书。有些句子要走过很远才读得懂。',
    entryIds: ['d05', 'd42'],
  },
  {
    id: 'c7', title: '相机里的四季', tone: 'moss',
    description: '第一卷没有拍好的照片，后来变成了每年秋天都会翻一遍的相册。',
    entryIds: ['d07', 'd12', 'd19', 'd20', 'd27', 'd41', 'd44'],
  },
  {
    id: 'c8', title: '工作之外', tone: 'sea',
    description: '项目会结束，会议会散。留下来的通常是下班以后的那一段路。',
    entryIds: ['d01', 'd08', 'd17', 'd22', 'd37'],
  },
];

const UNDERSTANDINGS = [
  {
    id: 'u1',
    statement: '换季的时候，你更常写下关于睡眠、窗子和天气的句子。',
    evidenceIds: ['d06', 'd13', 'd29'],
    scope: '2023–2026 · 春秋换季',
    status: 'pending',
    kind: 'rhythm',
  },
  {
    id: 'u2',
    statement: '跑步之后，你更容易记录轻快的句子，而不是疲惫。',
    evidenceIds: ['d09', 'd24', 'd35', 'd40'],
    scope: '2022–2026 · 跑步日',
    status: 'pending',
    kind: 'pattern',
  },
  {
    id: 'u3',
    statement: '你更喜欢在晚上整理照片，而不是当天。',
    evidenceIds: ['d07', 'd41'],
    scope: '2024–2026 · 照片记录',
    status: 'confirmed',
    kind: 'habit',
  },
  {
    id: 'u4',
    statement: '每年十月，你会想起上海。',
    evidenceIds: ['d21', 'd31'],
    scope: '2021–2026 · 十月',
    status: 'pending',
    kind: 'season',
  },
];

/* A compact, deliberately finite preview set.  Dates are relative to the day the
 * console is opened, so "on this day" and "最近" stay meaningful without shipping
 * a frozen snapshot. */
const ENTRIES = [
  {
    id: 'd01', when: { daysAgo: 0, time: '07:42' }, kind: 'journal',
    title: '窗边的十分钟', mood: '平静', place: '杭州·拱宸桥', weather: '晴',
    tags: ['早晨', '日常'], source: 'user', favorite: true, collections: ['c8'],
    body: '没有急着打开电脑。\n\n烧水，磨豆子，把窗推开一条缝。运河上有船过去，声音很慢。\n\n今天想把那件拖了很久的小事做完，不加班。',
  },
  {
    id: 'd02', when: { daysAgo: 1, time: '23:41' }, kind: 'journal',
    title: '把阳台的灯修好了', mood: '踏实', place: '家', weather: '多云',
    tags: ['家', '小事'], source: 'user', favorite: false,
    body: '灯泡换了三次才亮。站在阳台上看了一会儿，楼下那棵桂花树已经开了。\n\n一直觉得阳台只是个放杂物的地方，今晚突然觉得它也可以是一个房间。',
  },
  {
    id: 'd03', when: { daysAgo: 2, time: '19:20' }, kind: 'journal',
    title: '沿运河走到天黑', mood: '松弛', place: '杭州·拱宸桥', weather: '阴',
    tags: ['散步', '运河'], source: 'user', favorite: true,
    body: '从桥西走到小河直街，没有戴耳机。\n\n有人在河边钓鱼，有人推着婴儿车，有人在路灯下卖花。走到天黑的时候，突然不想回家，就又绕了一圈。',
  },
  {
    id: 'd04', when: { daysAgo: 4, time: '18:05' }, kind: 'journal',
    title: '一锅番茄牛腩', mood: '满足', place: '家', weather: '小雨',
    tags: ['做饭', '厨房'], source: 'user', favorite: false, collections: ['c3'],
    body: '番茄先炒出沙，牛腩焯水，小火炖了一个半小时。\n\n中途开盖尝了三次，最后一次才想起来放盐。汤拌饭很好吃，剩下的明天下面。',
  },
  {
    id: 'd05', when: { daysAgo: 9, time: '16:30' }, kind: 'journal',
    title: '雨停后去了书店', mood: '安静', place: '杭州·晓风书屋', weather: '雨后',
    tags: ['阅读', '雨天'], source: 'user', favorite: false, collections: ['c6'],
    body: '在靠窗的位置坐了一下午，翻完一本讲河流的书。\n\n有一段说，河流不会记得自己经过的每一块石头，但石头会记得水。抄在了本子上。',
  },
  {
    id: 'd06', when: { daysAgo: 16, time: '09:10' }, kind: 'journal',
    title: '十月的第一件毛衣', mood: '轻快', place: '杭州', weather: '凉',
    tags: ['季节', '日常'], source: 'user', favorite: false,
    body: '早上出门的时候有点凉，回家把去年那件灰色毛衣翻了出来。\n\n袖口有点起球，但穿上还是很舒服。秋天是真的来了。',
  },
  {
    id: 'd07', when: { daysAgo: 27, time: '22:15' }, kind: 'photo',
    title: '把夏天的照片整理完', mood: '怀念', place: '家', weather: '',
    tags: ['照片', '整理'], source: 'photo', favorite: false, collections: ['c7'],
    body: '从六月的海边开始，到八月的最后一次晚饭。\n\n删掉了三百多张，留下的也不都是好看的。有几张拍糊了，但记得当时在笑，就留着了。',
  },
  {
    id: 'd08', when: { daysAgo: 38, time: '21:40' }, kind: 'journal',
    title: '和阿禾吃饭，聊到很晚', mood: '温暖', place: '杭州·中山中路', weather: '晴',
    tags: ['朋友', '晚饭'], source: 'user', favorite: false, collections: ['c8'],
    body: '还是那家小馆子。她说最近在学陶艺，手上总是有泥。\n\n我们聊到很晚，出门的时候街上已经没什么人了。她说明年想去景德镇住一个月，我说好。',
  },
  {
    id: 'd09', when: { daysAgo: 53, time: '05:58' }, kind: 'auto',
    title: '跑完五公里，天刚亮', mood: '清醒', place: '杭州·西湖', weather: '晴',
    tags: ['跑步', '清晨'], source: 'auto', favorite: false, collections: ['c2'],
    body: '05:58 出门。北山街几乎没有车，湖面上有雾。\n\n06:31 跑完五公里，配速 6′12″。在长椅上坐了一会儿，看天一点点亮起来。\n\n07:10 回家，洗澡，做早饭。',
  },
  {
    id: 'd10', when: { daysAgo: 71, time: '14:20' }, kind: 'journal',
    title: '台风天，待在房间里', mood: '安静', place: '家', weather: '台风',
    tags: ['天气', '独处'], source: 'user', favorite: false, collections: ['c4'],
    body: '窗户关得很紧，还是能听见风。\n\n把昨天没看完的电影看完了，中间睡着了一次。醒来的时候天已经黑了，房间里只有冰箱在响。',
  },
  {
    id: 'd11', when: { daysAgo: 96, time: '20:12' }, kind: 'journal',
    title: '父亲的语音很长', mood: '想念', place: '家', weather: '',
    tags: ['家人', '电话'], source: 'user', favorite: false, collections: ['c5'],
    body: '他发了三条语音，加起来快两分钟。开头还是那句「没什么事」。\n\n说到最后才问，国庆回不回去。我说再看，他说好，然后把电话给了妈妈。',
  },
  {
    id: 'd12', when: { daysAgo: 120, time: '15:40' }, kind: 'photo',
    title: '第一次把相机带出门', mood: '新鲜', place: '杭州·小河直街', weather: '晴',
    tags: ['摄影', '第一次'], source: 'photo', favorite: false, collections: ['c7'],
    body: '在包里放了半天，到了街上反而不知道拍什么。\n\n最后拍的是河边一把旧椅子、一只睡在门口的花猫，还有一个骑三轮车卖菜的阿姨。回来发现只有猫那张是清楚的。',
  },
  {
    id: 'd13', when: { daysAgo: 150, time: '17:30' }, kind: 'journal',
    title: '春天最后一场雨', mood: '安静', place: '杭州', weather: '雨',
    tags: ['春天', '雨天'], source: 'user', favorite: false,
    body: '下班的时候雨刚停，地上全是湿的。\n\n路边的香樟落了一地花，踩上去有一点黏。春天好像就是这样结束的，没有告别。',
  },
  {
    id: 'd14', when: { daysAgo: 180, time: '11:00' }, kind: 'journal',
    title: '把书桌挪到窗边', mood: '明亮', place: '家', weather: '晴',
    tags: ['家', '布置'], source: 'user', favorite: false, collections: ['c3'],
    body: '搬了一个上午，腰有点酸。\n\n现在抬头就能看见对面的屋顶和一小块天。下午在这里看了二十页书，效率没有变高，但心情好了很多。',
  },
  {
    id: 'd15', when: { daysAgo: 210, time: '08:20' }, kind: 'journal',
    title: '清明回家', mood: '平静', place: '绍兴·安昌', weather: '阴',
    tags: ['家人', '清明'], source: 'user', favorite: false, collections: ['c5'],
    body: '早上的车，到的时候刚好赶上午饭。\n\n下午和父亲去了一趟老屋，门口的枇杷树比去年高了一截。他没有说什么，站了一会儿就回去了。',
  },
  {
    id: 'd16', when: { daysAgo: 240, time: '07:35' }, kind: 'journal',
    title: '开始认真做早饭', mood: '满足', place: '家', weather: '晴',
    tags: ['做饭', '早晨'], source: 'user', favorite: true, collections: ['c3'],
    body: '以前总是在路上买一个包子。这个月开始提前二十分钟起床，煮蛋、烤面包、切一个水果。\n\n没有变得更自律，只是觉得早上不应该那么慌。',
  },
  {
    id: 'd17', when: { daysAgo: 270, time: '09:15' }, kind: 'journal',
    title: '春节后第一个工作日', mood: '疲惫', place: '杭州', weather: '阴',
    tags: ['工作', '开工'], source: 'user', favorite: false, collections: ['c8'],
    body: '地铁里全是人，大家看起来都还没睡醒。\n\n开了一天的会，真正做完的事情不多。晚上回家煮了一碗面，决定明天早点睡。',
  },
  {
    id: 'd18', when: { daysAgo: 300, time: '19:00' }, kind: 'journal',
    title: '一个人过除夕', mood: '安静', place: '家', weather: '冷',
    tags: ['节日', '独处'], source: 'user', favorite: false, collections: ['c4'],
    body: '没有回家。给自己做了两个菜，开了一瓶啤酒，看了一会儿春晚。\n\n快到十二点的时候，楼下开始放烟花。我站在窗边看完，给家里发了视频，说这边很热闹。',
  },
  {
    id: 'd19', when: { daysAgo: 330, time: '16:50' }, kind: 'photo',
    title: '在厦门看海', mood: '开阔', place: '厦门·沙坡尾', weather: '晴',
    tags: ['旅行', '海'], source: 'photo', favorite: true, collections: ['c7'],
    body: '坐在堤岸上，看潮水一点点退下去。\n\n旁边有个小孩在捡贝壳，捡一个丢一个。风很大，头发一直吹到脸上。什么都没想，坐了很久。',
  },
  {
    id: 'd20', when: { daysAgo: 360, time: '21:30' }, kind: 'journal',
    title: '相册里的一年', mood: '怀念', place: '家', weather: '',
    tags: ['回顾', '照片'], source: 'user', favorite: false, collections: ['c7'],
    body: '把这一年拍的照片按月份排了一遍。\n\n一月在厨房，四月在江边，八月在大理，十一月在搬家的纸箱堆里。有些月份几乎没有照片，但那几个月发生了什么，还记得。',
  },
  {
    id: 'd21', when: { yearsAgo: 2, sameDay: true, time: '15:10' }, kind: 'journal',
    title: '在武康路走了一个下午', mood: '怀念', place: '上海·武康路', weather: '秋',
    tags: ['上海', '秋天'], source: 'user', favorite: true, collections: ['c1'],
    body: '回上海办点事，结束后没有急着走，沿着武康路一直走到安福路。\n\n梧桐叶刚开始黄，路边还是那些店。有一家咖啡馆换了招牌，其他好像都没变。走到以前住的那个路口，站了一会儿，没有进去。',
  },
  {
    id: 'd22', when: { yearsAgo: 4, sameDay: true, time: '14:00' }, kind: 'journal',
    title: '第一次在会上介绍自己的方案', mood: '紧张', place: '上海', weather: '',
    tags: ['工作', '第一次'], source: 'user', favorite: false, collections: ['c8'],
    body: '前一晚改了四遍，早上还是提前半小时到了会议室。\n\n讲的时候声音有点抖，但没有人打断。结束后主管说，逻辑是清楚的，细节再想想。这句话我记了很久。',
  },
  {
    id: 'd23', when: { yearsAgo: 2, month: 11, day: 18, time: '19:40' }, kind: 'journal',
    title: '搬家后的第一顿火锅', mood: '热闹', place: '杭州·拱宸桥', weather: '冷',
    tags: ['搬家', '朋友'], source: 'user', favorite: false, collections: ['c1'],
    body: '纸箱还没有拆完，锅先买了。\n\n阿禾和小满来吃饭，三个人坐在地上，围着一个小电磁炉。窗户上全是雾，有人说这才像搬家。',
  },
  {
    id: 'd24', when: { yearsAgo: 2, month: 9, day: 12, time: '06:20' }, kind: 'journal',
    title: '开始跑步的第一天', mood: '笨拙', place: '杭州·运河边', weather: '晴',
    tags: ['跑步', '第一次'], source: 'user', favorite: true, collections: ['c2'],
    body: '跑了两公里，走了三公里。\n\n鞋是新买的，路线是前一天晚上查好的。回家的时候腿有点软，但心情很好。先跑一个月看看。',
  },
  {
    id: 'd25', when: { yearsAgo: 3, month: 4, day: 9, time: '18:30' }, kind: 'journal',
    title: '复刻外婆的红烧肉', mood: '满足', place: '家', weather: '春',
    tags: ['做饭', '家人'], source: 'user', favorite: false, collections: ['c3'],
    body: '给妈妈打了电话，问外婆以前是怎么做的。她说要先用冰糖炒色，肉要选五花，火不能大。\n\n做出来味道不太一样，但已经很像了。拍了一张照片发给妈妈，她回了一个「好」。',
  },
  {
    id: 'd26', when: { yearsAgo: 3, month: 1, day: 21, time: '16:45' }, kind: 'journal',
    title: '父亲学会发照片', mood: '温暖', place: '绍兴·安昌', weather: '冬',
    tags: ['家人'], source: 'user', favorite: false, collections: ['c5'],
    body: '他发来一张院子里的腊梅，拍得有点歪。\n\n下面跟着一条语音，说今年开得好。我回了一个大拇指，他又发来一张，这次是猫。',
  },
  {
    id: 'd27', when: { yearsAgo: 3, month: 8, day: 16, time: '17:20' }, kind: 'photo',
    title: '在大理住了一周', mood: '开阔', place: '大理·才村', weather: '晴',
    tags: ['旅行', '夏天'], source: 'photo', favorite: false, collections: ['c7'],
    body: '每天睡到自然醒，骑车去村口吃米线。\n\n有一天什么都没做，在洱海边坐了一下午。风把云吹得很快，水面上一直有光。晚上回去的时候，突然不想回杭州。',
  },
  {
    id: 'd28', when: { yearsAgo: 4, month: 10, day: 6, time: '14:30' }, kind: 'journal',
    title: '来杭州的第一天', mood: '忐忑', place: '杭州·城站', weather: '晴',
    tags: ['搬家', '杭州'], source: 'user', favorite: true, collections: ['c1'],
    body: '两个行李箱，一个背包。\n\n出站的时候太阳很大，不知道往哪边走，在广场上站了一会儿。出租车司机问我去哪，我说了一个地址，他说那地方不远。\n\n那天晚上在空房间里铺好床，才觉得真的搬来了。',
  },
  {
    id: 'd29', when: { yearsAgo: 4, month: 12, day: 3, time: '22:00' }, kind: 'journal',
    title: '冬天的第一个电热毯', mood: '安稳', place: '家', weather: '冷',
    tags: ['冬天', '家'], source: 'user', favorite: false, collections: ['c4'],
    body: '杭州的冬天比上海更湿。\n\n把电热毯铺在床单下面，提前十分钟打开。钻进被窝的时候，觉得这个决定非常正确。',
  },
  {
    id: 'd30', when: { yearsAgo: 4, month: 6, day: 19, time: '21:10' }, kind: 'journal',
    title: '和阿禾在西湖边坐到很晚', mood: '放松', place: '杭州·西湖', weather: '夏',
    tags: ['朋友', '西湖'], source: 'user', favorite: false, collections: ['c1'],
    body: '买了两罐啤酒，坐在长椅上。\n\n她问我后不后悔搬来，我说还没有答案。她笑，说没有答案就是好答案。后来我们都没说话，看湖面上的灯。',
  },
  {
    id: 'd31', when: { yearsAgo: 5, month: 3, day: 2, time: '08:10' }, kind: 'journal',
    title: '离开上海前的最后一顿早饭', mood: '复杂', place: '上海·武康路', weather: '春',
    tags: ['上海', '搬家'], source: 'user', favorite: true, collections: ['c1'],
    body: '还是那家小店，豆浆、油条、一个茶叶蛋。\n\n吃完没有马上走，坐了一会儿。老板问今天怎么这么早，我说要搬家了。他说，上海挺好的呀。我说是挺好的。',
  },
  {
    id: 'd32', when: { yearsAgo: 5, month: 3, day: 1, time: '20:40' }, kind: 'journal',
    title: '收拾行李，丢掉了很多东西', mood: '疲惫', place: '上海', weather: '阴',
    tags: ['搬家', '整理'], source: 'user', favorite: false, collections: ['c1'],
    body: '五年攒下来的东西，最后只装了三个箱子。\n\n旧衣服、坏掉的台灯、一摞没有看完的杂志，都留在了楼下。有一本相册犹豫了很久，还是带走了。',
  },
  {
    id: 'd33', when: { yearsAgo: 1, month: 12, day: 21, time: '19:30' }, kind: 'journal',
    title: '冬至包了饺子', mood: '满足', place: '家', weather: '冷',
    tags: ['节日', '做饭'], source: 'user', favorite: false, collections: ['c3'],
    body: '和面的时候水放多了，又加了两勺面粉。\n\n包了二十多个，形状都不太一样。煮的时候破了三个，剩下的都很好。蘸醋吃，配一碗汤。',
  },
  {
    id: 'd34', when: { yearsAgo: 1, month: 7, day: 23, time: '18:50' }, kind: 'journal',
    title: '最热的一天，买了西瓜', mood: '慵懒', place: '杭州', weather: '酷热',
    tags: ['夏天', '日常'], source: 'user', favorite: false,
    body: '天气预报说 39 度。\n\n下班路上买了一个西瓜，抱回家的时候胳膊都酸了。切开一半，用勺子挖着吃，晚饭就这样解决了。',
  },
  {
    id: 'd35', when: { yearsAgo: 1, month: 4, day: 14, time: '07:05' }, kind: 'journal',
    title: '跑完第一个十公里', mood: '骄傲', place: '杭州·钱塘江边', weather: '晴',
    tags: ['跑步', '第一次'], source: 'user', favorite: true, collections: ['c2'],
    body: '前一晚有点睡不着，怕自己跑不完。\n\n前十公里比想象中慢，但一直没有停。到终点的时候没有欢呼，只是弯着腰喘气，然后笑了。\n\n回家的路上买了一杯豆浆，觉得今天可以算一个好日子。',
  },
  {
    id: 'd36', when: { yearsAgo: 1, month: 2, day: 10, time: '12:30' }, kind: 'journal',
    title: '春节回家，父亲在门口等', mood: '温暖', place: '绍兴·安昌', weather: '阴',
    tags: ['家人', '春节'], source: 'user', favorite: false, collections: ['c5'],
    body: '车到的时候他已经在门口了，穿着那件旧棉袄。\n\n接过我的箱子，说怎么又瘦了。我说没有。他没有再问，转身去厨房热菜。',
  },
  {
    id: 'd37', when: { monthsAgo: 6, day: 12, time: '10:20' }, kind: 'journal',
    title: '换了一个新项目', mood: '紧张', place: '杭州', weather: '晴',
    tags: ['工作', '变化'], source: 'user', favorite: false, collections: ['c8'],
    body: '新项目比想象中大，第一周几乎都在看资料。\n\n开会的时候插不上话，记了很多笔记。晚上回家把不懂的词查了一遍，感觉稍微踏实一点。',
  },
  {
    id: 'd38', when: { monthsAgo: 5, day: 8, time: '17:40' }, kind: 'journal',
    title: '阳台上的薄荷长疯了', mood: '惊喜', place: '家', weather: '晴',
    tags: ['家', '植物'], source: 'user', favorite: false, collections: ['c3'],
    body: '去年买的一小盆，现在已经长满了一个花箱。\n\n剪了一把泡水，剩下的晒在窗台上。原来有些东西不需要照顾得太仔细，也会自己长大。',
  },
  {
    id: 'd39', when: { monthsAgo: 4, day: 21, time: '20:15' }, kind: 'journal',
    title: '夏夜的第一声蝉', mood: '恍惚', place: '杭州', weather: '闷',
    tags: ['夏天', '夜晚'], source: 'user', favorite: false,
    body: '走在路上的时候突然听见的。\n\n停下来听了一会儿，又觉得好像不是蝉，是树上的什么声音。但那一刻确实是夏天。',
  },
  {
    id: 'd40', when: { monthsAgo: 3, day: 6, time: '06:40' }, kind: 'auto',
    title: '在雨里跑完三公里', mood: '畅快', place: '杭州·运河边', weather: '雨',
    tags: ['跑步', '雨天'], source: 'auto', favorite: false, collections: ['c2'],
    body: '06:40 开始下雨，还是出门了。\n\n雨不大，跑起来反而凉快。河面上全是细小的圆圈，跑到三公里的时候鞋已经湿透了。\n\n回家冲了一个热水澡，觉得这个早晨很值得。',
  },
  {
    id: 'd41', when: { monthsAgo: 2, day: 17, time: '22:50' }, kind: 'photo',
    title: '把旧照片扫描进电脑', mood: '怀念', place: '家', weather: '',
    tags: ['照片', '整理'], source: 'photo', favorite: false, collections: ['c7'],
    body: '翻出一盒以前的照片，有一张是大学门口的合影。\n\n很多人已经很久没有联系了。扫描的时候一张一张看过去，像在别人的相册里走了一圈。',
  },
  {
    id: 'd42', when: { monthsAgo: 2, day: 2, time: '21:25' }, kind: 'journal',
    title: '读完一本讲河流的书', mood: '安静', place: '家', weather: '',
    tags: ['阅读', '书'], source: 'user', favorite: false, collections: ['c6'],
    body: '最后一章写到一条河改道，原来的河床变成了路。\n\n合上书之后坐了一会儿。想起小时候外婆家后面那条小河，不知道现在还在不在。',
  },
  {
    id: 'd43', when: { monthsAgo: 1, day: 26, time: '20:00' }, kind: 'journal',
    title: '中秋没有回家', mood: '想念', place: '杭州', weather: '晴',
    tags: ['节日', '家人'], source: 'user', favorite: false, collections: ['c5'],
    body: '晚上和家里视频，镜头扫过一桌菜，母亲说给你留了螃蟹。\n\n挂掉之后去楼下买了一块月饼，坐在阳台上吃完。月亮很亮，楼下有人在遛狗。',
  },
  {
    id: 'd44', when: { daysAgo: 21, time: '16:10' }, kind: 'photo',
    title: '收到了新的镜头', mood: '期待', place: '家', weather: '晴',
    tags: ['摄影', '礼物'], source: 'photo', favorite: false, collections: ['c7'],
    body: '拆开之后先对着窗外拍了一张，虚了。\n\n看了一下午教程，傍晚又出去试了一次。拍到了运河上的落日，虽然构图很普通，但自己很喜欢。',
  },
  {
    id: 'd45', when: { yearsAgo: 3, month: 10, day: 2, time: '15:30' }, kind: 'journal',
    title: '上海的朋友来杭州', mood: '开心', place: '杭州·西湖', weather: '晴',
    tags: ['朋友', '杭州'], source: 'user', favorite: false, collections: ['c1'],
    body: '带他们走了断桥和白堤，人很多，但大家都不着急。\n\n晚上在河坊街吃饭，聊起以前在上海的日子，像在说另一份人生。临走的时候他们说，杭州挺好的。',
  },
  {
    id: 'd46', when: { monthsAgo: 15, day: 11, time: '09:30' }, kind: 'journal',
    title: '第一次在阳台种番茄', mood: '新鲜', place: '家', weather: '春',
    tags: ['植物', '家'], source: 'user', favorite: false, collections: ['c3'],
    body: '买了两棵小苗，按照网上的教程换了盆。\n\n每天早上浇一点水，隔几天转一次方向。长得比想象中慢，但确实在长。',
  },
  {
    id: 'd47', when: { monthsAgo: 22, day: 5, time: '06:30' }, kind: 'photo',
    title: '冬天早上六点的河', mood: '清醒', place: '杭州·运河边', weather: '雾',
    tags: ['冬天', '跑步', '照片'], source: 'photo', favorite: false, collections: ['c2'],
    body: '出门的时候天还没亮，河面上有一层很薄的雾。\n\n跑了一小段就停下来了，拍了一张。照片里几乎什么都看不清，只有桥的轮廓。',
  },
  {
    id: 'd48', when: { yearsAgo: 2, month: 5, day: 20, time: '13:20' }, kind: 'journal',
    title: '换掉用了五年的手机', mood: '不舍', place: '杭州', weather: '',
    tags: ['日常', '变化'], source: 'user', favorite: false,
    body: '旧手机屏幕裂了很久，一直没换。\n\n把照片和聊天记录导过去，花了两个小时。最后把旧手机擦干净的时候，突然有点空。它陪我搬过两次家。',
  },
  {
    id: 'd49', when: { yearsAgo: 1, month: 10, day: 12, time: '19:15' }, kind: 'journal',
    title: '去上海出了一天差', mood: '恍惚', place: '上海·虹桥', weather: '秋',
    tags: ['上海', '工作'], source: 'user', favorite: false, collections: ['c1'],
    body: '早上的高铁，晚上的高铁，中间开了两个会。\n\n结束得比预期早，本来想去武康路走走，看了看时间还是直接去了车站。在候车厅买了一杯咖啡，想起以前下班也常走这条路。',
  },
];

function resolveWhen(when, now) {
  if (!when) return new Date(now);
  if (typeof when.daysAgo === 'number') return addDays(now, -when.daysAgo);
  if (typeof when.monthsAgo === 'number') {
    return new Date(now.getFullYear(), now.getMonth() - when.monthsAgo, when.day ?? 15, 12);
  }
  if (typeof when.yearsAgo === 'number') {
    if (when.sameDay) return new Date(now.getFullYear() - when.yearsAgo, now.getMonth(), now.getDate(), 12);
    return new Date(now.getFullYear() - when.yearsAgo, (when.month ?? 1) - 1, when.day ?? 1, 12);
  }
  return new Date(now);
}

export function buildDemoArchive(now = new Date()) {
  const entries = ENTRIES.map((entry) => {
    const date = resolveWhen(entry.when, now);
    return {
      id: entry.id,
      occurred_at: `${dateKey(date)}T${entry.when?.time ?? '12:00'}:00+08:00`,
      kind: entry.kind,
      title: entry.title,
      body: entry.body,
      tags: entry.tags,
      place: entry.place,
      mood: entry.mood,
      weather: entry.weather,
      source: entry.source,
      favorite: entry.favorite,
      collectionIds: entry.collections ?? [],
      tone: COLLECTIONS.find((collection) => collection.id === entry.collections?.[0])?.tone,
    };
  });
  return {
    format: MIRROR_FORMAT,
    version: MIRROR_VERSION,
    exported_at: new Date(now).toISOString(),
    demo: true,
    persona: DEMO_PERSONA,
    entries,
    collections: COLLECTIONS,
    understandings: UNDERSTANDINGS,
  };
}

export const DEMO_COLLECTIONS = COLLECTIONS;
export const DEMO_UNDERSTANDINGS = UNDERSTANDINGS;
