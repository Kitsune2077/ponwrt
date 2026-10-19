'use strict';
'require baseclass';
'require fs';
'require network';
'require uci';

/* 概览页 PON 光模块卡片（include 序号 15，渲染在「系统」与「内存」之间）。
 * 光学数据与 luci-app-pon 状态页同源（ponctl status --json），
 * 执行权限由 luci-app-pon 的 rpcd ACL 覆盖；本包自带的 ACL 只补充两项：
 * 读取 /proc/stat（CPU 使用率行增强）和执行 pon-overview-stats（conntrack 卸载统计）。
 *
 * 另外本卡片在每次轮询时会把概览页「系统」表格中的 CPU 使用率一行增强为
 * USR/SYS/每核占用明细。该行由 luci-mod-status 的 10_system.js 渲染且 feed 不可
 * 修改，所以按标签文案（经 _() 翻译，与渲染方一致）定位该行后替换其值单元格；
 * 定位失败时静默放弃，保留原始的单值显示。
 *
 * 文案直接使用中文 msgid（_() 无翻译目录时回显原文），不依赖 .lmo。 */

/* 字段顺序与小数位对齐概览卡片版式：收/发光功率与温度两位小数，电压保留
 * ponctl 的 4 位原始精度。 */
var frontendRows = [
	{ field: 'rx_power_dbm',        label: _('收光功率'),   unit: 'dBm', digits: 2 },
	{ field: 'tx_power_dbm',        label: _('发光功率'),   unit: 'dBm', digits: 2 },
	{ field: 'temperature_celsius', label: _('光模块温度'), unit: '°C',  digits: 2 },
	{ field: 'tx_bias_ma',          label: _('偏置电流'),   unit: 'mA',  digits: 2 },
	{ field: 'voltage_volts',       label: _('供电电压'),   unit: 'V',   digits: 4 }
];

var cardStyle = '\
#pon_overview_status .pon-mod-card { \
	border: 1px solid rgba(128, 128, 128, .25); \
	border-radius: 8px; \
	overflow: hidden; \
	margin-bottom: .6em; \
} \
#pon_overview_status .pon-mod-header { \
	background: #5a67d8; \
	color: #fff; \
	font-weight: 700; \
	text-align: center; \
	padding: .45em 1em; \
} \
#pon_overview_status .pon-mod-body { \
	display: flex; \
	align-items: center; \
	justify-content: space-between; \
	flex-wrap: wrap; \
	gap: 1em 2em; \
	padding: .9em 1.2em; \
} \
#pon_overview_status .pon-mod-rows { \
	display: flex; \
	flex-direction: column; \
	gap: .35em; \
	flex: 1 1 16em; \
} \
#pon_overview_status .pon-mod-row { display: flex; gap: .3em; } \
#pon_overview_status .pon-mod-label { font-weight: 700; } \
#pon_overview_status .pon-mod-rates { \
	display: flex; \
	flex-direction: column; \
	gap: .6em; \
	text-align: right; \
	flex: 0 0 auto; \
} \
#pon_overview_status .pon-mod-rate { display: flex; align-items: baseline; gap: .45em; } \
#pon_overview_status .pon-mod-rate-label { opacity: .7; } \
#pon_overview_status .pon-mod-rate-num { font-size: 1.45em; font-weight: 700; line-height: 1; } \
#pon_overview_status .pon-mod-rate-unit { font-size: .8em; opacity: .7; } \
#pon_overview_status .pon-mod-footer { \
	display: flex; \
	flex-wrap: wrap; \
	gap: .4em 1.8em; \
	padding: .55em 1.2em; \
	border-top: 1px solid rgba(128, 128, 128, .25); \
	font-size: .9em; \
} \
#pon_overview_status .pon-mod-footer b { font-size: 1.15em; } \
#pon_overview_status .pon-mod-offload { color: #3fb950; font-weight: 700; } \
@media (max-width: 640px) { \
	#pon_overview_status .pon-mod-body { flex-direction: column; align-items: stretch; } \
	#pon_overview_status .pon-mod-rates { \
		flex-direction: row; \
		justify-content: space-around; \
		text-align: center; \
		border-top: 1px solid rgba(128, 128, 128, .15); \
		padding-top: .7em; \
	} \
}';

/* 轮询间的上下行速率采样与 /proc/stat 差值基线，均为页面级状态。 */
var trafficPrev = {},
    cpuPrev = null;

function execJSON(command, args) {
	return L.resolveDefault(fs.exec_direct(command, args), null)
		.then(function(output) {
			if (output == null)
				return null;
			try { return JSON.parse(output); }
			catch (e) { return null; }
		});
}

function frontendMetric(frontend, field, unit, digits) {
	if (frontend == null || frontend.error)
		return _('读取失败');
	if (frontend[field] == null)
		return _('不支持');
	return Number(frontend[field]).toFixed(digits) + ' ' + unit;
}

function pct(part, whole) {
	return (whole > 0) ? Math.min(100, Math.round(100 * part / whole)) : 0;
}

function rateLine(label, mbps) {
	if (mbps != null && mbps < 0)
		mbps = 0;

	return E('div', { 'class': 'pon-mod-rate' }, [
		E('span', { 'class': 'pon-mod-rate-label' }, [ label ]),
		E('span', { 'class': 'pon-mod-rate-num' },
			[ (mbps == null) ? '—' : mbps.toFixed(2) ]),
		E('span', { 'class': 'pon-mod-rate-unit' }, [ 'Mbit/s' ])
	]);
}

function rateBlock(name, traffic) {
	var node = E('div', { 'class': 'pon-mod-rates' }),
	    cur = (traffic != null) ? traffic[name] : null,
	    prev = trafficPrev[name],
	    dt = (cur != null && prev != null) ? (cur.t - prev.t) / 1000 : 0;

	if (dt > 0) {
		node.appendChild(rateLine(_('上行'), (cur.tx - prev.tx) * 8 / dt / 1e6));
		node.appendChild(rateLine(_('下行'), (cur.rx - prev.rx) * 8 / dt / 1e6));
	}
	else {
		node.appendChild(rateLine(_('上行'), null));
		node.appendChild(rateLine(_('下行'), null));
	}

	if (cur != null)
		trafficPrev[name] = cur;

	return node;
}

function conntrackFooter(raw) {
	if (raw == null)
		return null;

	var v = String(raw).trim().split(/\s+/).map(Number);

	if (v.length < 4 || v.some(isNaN))
		return null;

	function entries(proto, total, offload) {
		return E('span', {}, [
			proto + ' ',
			E('b', {}, [ total.toLocaleString() ]),
			' ' + _('卸载') + ' ',
			E('span', { 'class': 'pon-mod-offload' }, [ offload.toLocaleString() ])
		]);
	}

	return E('div', { 'class': 'pon-mod-footer' }, [
		entries('TCP', v[0], v[1]),
		entries('UDP', v[2], v[3])
	]);
}

/* /proc/stat → { total: {user, sys, idle, total}, cores: [...] }，时间单位为
 * 内核 jiffies。user 含 nice，sys 含硬/软中断，idle 含 iowait。 */
function parseProcStat(text) {
	var result = { total: null, cores: [] };

	String(text).split('\n').forEach(function(line) {
		var m = line.match(/^(cpu\d*)\s+(.*)$/);

		if (m == null)
			return;

		var v = m[2].trim().split(/\s+/).map(Number),
		    entry = {
		    	user:  (v[0] || 0) + (v[1] || 0),
		    	sys:   (v[2] || 0) + (v[5] || 0) + (v[6] || 0),
		    	idle:  (v[3] || 0) + (v[4] || 0),
		    	total: 0
		    };

		for (var i = 0; i < 8 && i < v.length; i++)
			entry.total += (v[i] || 0);

		if (m[1] == 'cpu')
			result.total = entry;
		else
			result.cores.push(entry);
	});

	return result;
}

function augmentCpuRow(procstat) {
	var cur = parseProcStat(procstat);

	if (cur.total == null)
		return;

	var prev = cpuPrev;

	cpuPrev = cur;

	/* 首次采样只记录基线，下一个轮询周期才有差值可算。 */
	if (prev == null)
		return;

	function delta(now, before) { return Math.max(0, now - before); }

	var dTotal = delta(cur.total.total, prev.total.total);

	if (dTotal <= 0)
		return;

	var text = 'USR: ' + pct(delta(cur.total.user, prev.total.user), dTotal) +
	           '% SYS: ' + pct(delta(cur.total.sys, prev.total.sys), dTotal) + '%';

	if (cur.cores.length && cur.cores.length == prev.cores.length) {
		text += ' · ' + cur.cores.map(function(core, i) {
			return 'CPU' + i + ' ' + pct(delta(core.total - core.idle,
				prev.cores[i].total - prev.cores[i].idle), dTotal) + '%';
		}).join(' ');
	}

	/* 概览页各 include 的渲染顺序与 10_system 一致，但首次载入时页面 DOM
	 * 尚未挂载，因此在挂载后按系统表格的标签文案定位重试。 */
	var label = _('CPU usage (%)'),
	    tries = 0;

	(function attempt() {
		var sections = document.querySelectorAll('div.cbi-section');

		for (var i = 0; i < sections.length; i++) {
			var h3 = sections[i].querySelector('h3');

			if (h3 == null || h3.firstChild == null ||
			    h3.firstChild.textContent != _('System'))
				continue;

			var rows = sections[i].querySelectorAll('tr');

			for (var j = 0; j < rows.length; j++) {
				var tds = rows[j].querySelectorAll('td');

				if (tds.length >= 2 && tds[0].textContent == label) {
					tds[1].textContent = text;
					return;
				}
			}
		}

		if (++tries < 20)
			window.setTimeout(attempt, 100);
	})();
}

function buildCard(item, traffic) {
	var rows = E('div', { 'class': 'pon-mod-rows' });

	if (item.error) {
		rows.appendChild(E('div', { 'class': 'pon-mod-row' }, [
			E('span', { 'class': 'pon-mod-label' }, [ _('错误') + ':' ]),
			E('span', {}, [ item.error ])
		]));
	}
	else {
		var frontend = item.snapshot.frontend || {};

		frontendRows.forEach(function(r) {
			rows.appendChild(E('div', { 'class': 'pon-mod-row' }, [
				E('span', { 'class': 'pon-mod-label' }, [ r.label + ':' ]),
				E('span', {}, [ frontendMetric(frontend, r.field, r.unit, r.digits) ])
			]));
		});
	}

	return E('div', { 'class': 'pon-mod-card' }, [
		E('div', { 'class': 'pon-mod-header' }, [ item.device ]),
		E('div', { 'class': 'pon-mod-body' }, [
			rows,
			rateBlock(item.device, traffic)
		])
	]);
}

return baseclass.extend({
	title: _('PON 光模块'),

	load: function() {
		return L.resolveDefault(uci.load('pon'), null).then(function() {
			var sections = uci.sections('pon', 'xpon');

			if (!sections.length)
				return null;

			var lineJobs = sections.map(function(s) {
				var device = s.device || '';

				if (!device)
					return Promise.resolve({ section: s, device: device, error: _('未配置设备') });

				return execJSON('/usr/sbin/ponctl', [ '--device', device, 'status', '--json' ])
					.then(function(snapshot) {
						if (snapshot == null || snapshot.schema_version !== 1 || !snapshot.line)
							return { section: s, device: device, error: _('无法读取 PON 线路状态') };

						return { section: s, device: device, snapshot: snapshot };
					});
			});

			return Promise.all([
				Promise.all(lineJobs),
				L.resolveDefault(network.getDevices(), []).then(function(devices) {
					var now = Date.now(),
					    map = {};

					devices.forEach(function(d) {
						map[d.getName()] = { t: now, tx: d.getTXBytes(), rx: d.getRXBytes() };
					});

					return map;
				}),
				L.resolveDefault(fs.exec_direct('/usr/libexec/pon-overview-stats'), null),
				L.resolveDefault(fs.read('/proc/stat'), null)
			]).then(function(results) {
				return {
					lines: results[0],
					traffic: results[1],
					conntrack: results[2],
					procstat: results[3]
				};
			});
		});
	},

	render: function(data) {
		if (data == null || !data.lines.length)
			return null;

		var root = E('div', { 'id': 'pon_overview_status' }, [
			E('style', { 'type': 'text/css' }, [ cardStyle ])
		]);

		data.lines.forEach(function(item) {
			root.appendChild(buildCard(item, data.traffic));
		});

		/* 脚注为整机 conntrack 统计，挂到卡片底部，与截图版式一致。 */
		var footer = conntrackFooter(data.conntrack);

		if (footer != null)
			root.lastChild.appendChild(footer);

		if (data.procstat != null)
			augmentCpuRow(data.procstat);

		return root;
	}
});
