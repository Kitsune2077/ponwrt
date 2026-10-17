'use strict';
'require baseclass';
'require fs';
'require uci';

/* 概览页 PON 状态卡片。数据源与 luci-app-pon 状态页相同（ponctl/pondctl），
 * 执行权限由 luci-app-pon 的 rpcd ACL 覆盖。
 * 文案直接使用中文 msgid（_() 无翻译目录时回显原文），不依赖 .lmo。 */

var modeLabels = {
	gpon: _('GPON'),
	xgpon: _('XG-PON'),
	xgspon: _('XGS-PON'),
	'epon-1g': _('EPON 1G/1G'),
	'epon-10g-1g': _('10G-EPON 10G/1G'),
	'epon-10g-10g': _('10G-EPON 10G/10G')
};

var lifecycleLabels = {
	stopped: _('已停止'),
	'wait-optical-signal': _('等待光信号'),
	'pma-configured': _('PMA 已配置'),
	'wait-line-sync': _('等待线路同步'),
	'protocol-activating': _('协议激活中'),
	operational: _('运行中'),
	error: _('错误')
};

var syncLabels = {
	'not-applicable': _('不适用'),
	hunt: _('搜索同步'),
	'pre-sync': _('预同步'),
	'in-sync': _('已同步'),
	're-sync': _('重新同步中')
};

var onuStateLabels = {
	O1: _('O1 — 初始状态'),
	O2_3: _('O2-3 — 序列号'),
	O4: _('O4 — 测距'),
	O5: _('O5 — 运行'),
	O7: _('O7 — 紧急停止')
};

var mpcpLabels = {
	wait: _('等待发现'),
	registering: _('等待发现门'),
	'register-request': _('已发送注册请求'),
	'register-pending': _('收到注册，ACK 待发'),
	registered: _('已注册'),
	denied: _('注册被拒绝')
};

var authLabels = {
	'not-requested': _('OLT 未请求认证'),
	pending: _('等待中'),
	'not-reported': _('OLT 尚未上报'),
	'not-authenticated': _('未通过认证'),
	accepted: _('已通过'),
	'loid-not-found': _('LOID 不存在'),
	'password-mismatch': _('LOID 存在但密码错误'),
	'loid-conflict': _('LOID 已被其它 ONU 认证'),
	'reserved-status': _('保留的认证状态')
};

function lookup(map, key) {
	return (key != null && key !== '' && map[key]) || key || _('未知');
}

function booleanLabel(value) {
	if (value === true || value === 1 || value === '1')
		return _('是');
	if (value === false || value === 0 || value === '0')
		return _('否');
	return _('未知');
}

function frontendMetric(frontend, field, unit) {
	if (frontend == null || frontend.error)
		return _('读取失败');
	if (frontend[field] == null)
		return _('不支持');
	return Number(frontend[field]).toFixed(2) + ' ' + unit;
}

function execJSON(command, args) {
	return L.resolveDefault(fs.exec_direct(command, args), null)
		.then(function(output) {
			if (output == null)
				return null;
			try { return JSON.parse(output); }
			catch (e) { return null; }
		});
}

/* 行结构对齐 luci-base 自带的 status include（tr/td class + width 属性）：
 * 主题的小屏响应式规则作用在 .td 类上，裸 td 会漏掉这些规则，小屏下表格
 * 内容收缩、右侧留白；width 属性只在没有 CSS 覆盖时生效，正好作为桌面端
 * 的列宽提示。 */
function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left pon-label', 'width': '42%' }, label),
		E('td', { 'class': 'td left' }, (value == null || value === '') ? _('未知') : String(value))
	]);
}

function lineRows(item, omci) {
	var snap = item.snapshot,
	    line = snap.line || {},
	    frontend = snap.frontend || {},
	    registration = snap.registration || {},
	    mode = line.active_mode || item.section.mode || '',
	    epon = mode.indexOf('epon-') === 0,
	    rows;

	rows = [
		row(_('线路模式'), lookup(modeLabels, mode || 'none')),
		row(_('线路状态'), lookup(lifecycleLabels, line.lifecycle)),
		row(epon ? _('MPCP 状态') : _('ONU 状态'),
		    epon ? lookup(mpcpLabels, registration.mpcp_state)
		         : lookup(onuStateLabels, registration.onu_state)),
		row(epon ? _('LLID') : _('ONU-ID'),
		    epon ? (registration.llid_valid === true ? registration.llid : _('未分配'))
		         : (registration.onu_id_valid === true ? registration.onu_id : _('未分配'))),
		row(_('已检测到光信号'), booleanLabel(line.optical_signal)),
		row(_('接收光功率'), frontendMetric(frontend, 'rx_power_dbm', 'dBm')),
		row(_('发射光功率'), frontendMetric(frontend, 'tx_power_dbm', 'dBm')),
		row(_('光模块温度'), frontendMetric(frontend, 'temperature_celsius', '°C'))
	];

	if (!epon) {
		rows.push(row(mode === 'gpon' ? _('GTC 状态') : _('XGTC 状态'),
		    lookup(syncLabels, line.xgtc_sync)));

		if (omci != null) {
			var olt = [ omci.olt_vendor_id, omci.olt_equipment_id ]
				.filter(function(v) { return v != null && v !== ''; })
				.join(' / ');

			rows.push(
				row(_('OMCI 通道在线'), booleanLabel(omci.channel_available)),
				row(_('OLT 设备 ID'), olt || _('未知')),
				row(_('LOID 认证结果'), lookup(authLabels, omci.authentication_meaning)));
		}
	}

	return rows;
}

return baseclass.extend({
	title: _('PON'),

	load: function() {
		return L.resolveDefault(uci.load('pon'), null).then(function() {
			var sections = uci.sections('pon', 'xpon');

			if (!sections.length)
				return null;

			var lineByName = {};
			sections.forEach(function(s) { lineByName[s['.name']] = s; });

			var lineJobs = sections.map(function(s) {
				var device = s.device || '';

				if (!device)
					return Promise.resolve({ section: s, error: _('未配置设备') });

				return execJSON('/usr/sbin/ponctl', [ '--device', device, 'status', '--json' ])
					.then(function(snapshot) {
						if (snapshot == null || snapshot.schema_version !== 1 || !snapshot.line)
							return { section: s, error: _('无法读取 PON 线路状态') };

						return { section: s, snapshot: snapshot };
					});
			});

			var omciJobs = uci.sections('pon', 'omci').filter(function(s) {
				var line = lineByName[s.line];
				return line && (line.mode || '').indexOf('epon-') !== 0;
			}).map(function(s) {
				return execJSON('/usr/bin/pondctl', [ 'status', '--line', s.line ])
					.then(function(values) {
						return { name: s.line, values: values };
					});
			});

			return Promise.all([ Promise.all(lineJobs), Promise.all(omciJobs) ])
				.then(function(results) {
					return { lines: results[0], omci: results[1] };
				});
		});
	},

	render: function(data) {
		if (data == null || !data.lines.length)
			return null;

		var omciByLine = {};
		data.omci.forEach(function(item) { omciByLine[item.name] = item.values; });

		var nodes = data.lines.map(function(item) {
			var rows;

			if (item.error)
				rows = [ row(_('错误'), item.error) ];
			else
				rows = lineRows(item, omciByLine[item.section['.name']]);

			if (data.lines.length > 1)
				rows.unshift(row(_('线路'), item.section['.name']));

			return E('table', { 'class': 'table' }, rows);
		});

		nodes.push(E('div', { 'style': 'text-align: right' },
			E('a', {
				'href': L.url('admin/network/pon/status'),
				'class': 'button'
			}, [ _('PON 状态'), ' »' ])));

		return E('div', { 'id': 'pon_overview_status' }, nodes);
	}
});
