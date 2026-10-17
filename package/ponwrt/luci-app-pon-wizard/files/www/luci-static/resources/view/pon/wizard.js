'use strict';
'require view';
'require dom';
'require fs';
'require poll';
'require ui';
'require uci';

/* PON 接入向导：桥接 2.5G 口给下游 PPPoE、设置运营商 VLAN、选择管理访问
 * 方案（FLASHING.md 第 6 / 6.4 / 6.7 节）。表单按 pon-wizard-apply 报告的
 * 「实际状态」预填——已手工配置过方案 B/C 的光猫打开即勾选对应选项。
 *
 * 文案直接使用中文 msgid（_() 在无翻译目录时回显原文），不依赖 .lmo。 */

var APPLY = '/usr/libexec/pon-wizard-apply';

var schemeLabels = {
	none: _('禁用（清除已应用的管理访问配置）'),
	A: _('方案 A —— 单独一根管理网线（光猫侧无需改动）'),
	B: _('方案 B —— 单线复用（管理 VLAN 打 tag）'),
	C: _('方案 C —— 单线并存（untagged 管理 IP + 路由器插件）')
};

function execJSON(args) {
	return L.resolveDefault(fs.exec_direct(APPLY, args), null)
		.then(function(output) {
			if (output == null)
				return null;
			try { return JSON.parse(output); }
			catch (e) { return null; }
		});
}

function fetchStatus() {
	return execJSON([ 'status' ]);
}

function effective(detected, declared, key, dkey) {
	/* 实际状态优先于保存的声明：手工配置过 B/C 的光猫打开即勾选 */
	var d = detected;
	if (dkey != null) {
		d = null;
		if (detected != null && detected[dkey] != null && detected[dkey] !== '' &&
		    !(typeof(detected[dkey]) == 'object' && detected[dkey].scheme == 'none'))
			d = detected[dkey];
	}
	if (d != null && d !== '' && d !== false)
		return d;
	var v = (declared != null && declared[key] != null) ? declared[key] : '';
	return (v === '0' || v === 'none') ? '' : v;
}

function fieldRow(title, widget, hint) {
	var field = E('div', { 'class': 'cbi-value-field' },
		Array.isArray(widget) ? widget : [ widget ]);
	if (hint)
		field.appendChild(E('div', { 'class': 'cbi-value-description' }, hint));
	return E('div', { 'class': 'cbi-value' }, [
		E('div', { 'class': 'cbi-value-title' }, title),
		field
	]);
}

var ipv4Re = /^(\d{1,3}\.){3}\d{1,3}$/;
var vidRe = /^[0-9]{1,4}$/;

function validVid(v) {
	if (!vidRe.test(v))
		return false;
	var n = +v;
	return n >= 1 && n <= 4094;
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('ponwizard'), null),
			fetchStatus()
		]);
	},

	render: function(data) {
		var declared = (data[0] == null) ? {} : (uci.get('ponwizard', 'config') || {});
		var status = data[1];

		var container = E('div', { 'id': 'pon-wizard' }, [
			this.renderStatus(status),
			this.renderForm(status, declared)
		]);

		poll.add(L.bind(function() {
			fetchStatus().then(L.bind(function(st) {
				if (st == null)
					return;
				dom.content(container.querySelector('#pw-timer-slot'),
					this.renderTimer(st));
				var sync = container.querySelector('#pw-sync-slot');
				if (sync)
					sync.parentNode.style.display = st.in_sync ? 'none' : '';
			}, this));
		}, this), 3);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('PON 接入向导')),
			E('div', { 'class': 'cbi-map-descr' },
				_('桥接 2.5G 口给下游 PPPoE 拨号、设置运营商 VLAN，并选择下游路由器访问光猫管理页的方式。已有配置会被自动识别。')),
			container
		]);
	},

	renderStatus: function(status) {
		if (status == null)
			return E('div', { 'class': 'cbi-section' },
				E('p', { 'class': 'alert-message warning' },
					_('无法读取当前状态（%s 缺失或执行失败）。').format(APPLY)));

		var mgmt;
		switch (status.mgmt.scheme) {
			case 'B':
				mgmt = _('方案 B（管理 VLAN %s）').format(status.mgmt.vid);
				break;
			case 'C':
				mgmt = _('方案 C（%s 挂 %s，仅放行 %s）').format(
					status.mgmt.ip, status.mgmt.parent, status.mgmt.router || '?');
				break;
			default:
				mgmt = _('无');
		}

		/* 行结构对齐 luci-base 的 status include（同概览页 PON 卡片的处理）：
		 * .tr/.td class 让主题的小屏响应式规则生效，width 属性作为桌面端列宽 */
		var row = function(l, v) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left pw-label', 'width': '42%' }, l),
				E('td', { 'class': 'td left' }, (v == null || v === '') ? _('未知') : String(v))
			]);
		};

		var modeDesc;
		if (status == null)
			modeDesc = _('未知');
		else if (status.op_mode == 'router') {
			modeDesc = _('路由（光猫拨号');
			if (status.router_vid)
				modeDesc += _('，VLAN %s').format(status.router_vid);
			if (status.pppoe_user)
				modeDesc += _('，账号 %s').format(status.pppoe_user);
			modeDesc += '）';
		}
		else
			modeDesc = _('桥接（%s = %s + %s）').format(status.pon_bridge, status.pon_port, status.port25);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('检测到的状态')),
			E('div', { 'id': 'pw-sync-slot' }, !status.in_sync
				? E('p', { 'class': 'alert-message notice' },
					_('检测到的实际配置与保存的声明不一致：保存后系统将按下方表单收敛。'))
				: E([])),
			E('table', { 'class': 'table' }, [
				row(_('工作模式'), modeDesc),
				row(_('运营商 VLAN'), status.isp_vid || status.router_vid || _('无（untagged）')),
				row(_('管理访问'), mgmt)
			]),
			E('div', { 'id': 'pw-timer-slot' }, this.renderTimer(status))
		]);
	},

	renderTimer: function(status) {
		if (status.timer == null || !status.timer.armed)
			return E([]);

		var secs = status.timer.remaining || 0;
		var mm = String(Math.floor(secs / 60)).padStart(2, '0');
		var ss = String(secs % 60).padStart(2, '0');

		return E('p', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('回滚保险已武装：')), ' ',
			_('配置已应用但尚未确认，%s:%s 后将自动恢复原状。').format(mm, ss), ' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-apply important',
				'click': ui.createHandlerFn(this, function() {
					return fs.exec_direct(APPLY, [ 'confirm' ]).then(L.bind(this.refresh, this));
				})
			}, _('确认保留')), ' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function() {
					return fs.exec_direct(APPLY, [ 'revert' ]).then(L.bind(this.refresh, this));
				})
			}, _('立即回滚'))
		]);
	},

	renderForm: function(status, declared) {
		var det = status || {};
		var detMgmt = det.mgmt || { scheme: 'none' };

		var vOpMode = (det.op_mode != null && det.op_mode !== '') ? det.op_mode
			: (declared.op_mode != null ? declared.op_mode : 'bridge');
		var vBridged = !!(det.bridged || effective(null, declared, 'bridged'));
		var vPort25 = det.port25 || (declared.port25 != null && declared.port25 !== '' ? declared.port25 : 'lan1');
		var vVlanEn = !!(det.isp_vid || det.router_vid || effective(null, declared, 'wan_vlan_enabled'));
		var vVlan = det.isp_vid || det.router_vid || declared.wan_vlan || '';
		var vUser = det.pppoe_user || declared.pppoe_user || '';
		var vIpv6 = (declared.wan_ipv6 == null) ? true : (declared.wan_ipv6 == '1');
		var vScheme = (detMgmt.scheme != 'none') ? detMgmt.scheme
			: (declared.mgmt_scheme != null ? declared.mgmt_scheme : 'none');
		var vMgmtVlan = detMgmt.vid || declared.mgmt_vlan || '2100';
		var vMgmtIp = detMgmt.ip || declared.mgmt_ip || '192.168.9.1';
		var vMgmtRtr = detMgmt.router || declared.mgmt_router_ip || '192.168.9.254';

		/* 端口候选：检测到的千兆口 + 检测/声明的 2.5G 口 */
		var portCand = (det.gbe_ports || []).slice();
		[ vPort25, 'lan1' ].forEach(function(p) {
			if (p && portCand.indexOf(p) < 0)
				portCand.push(p);
		});
		portCand.sort();

		var elMode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'bridge', 'selected': (vOpMode == 'bridge') ? 'selected' : null },
				_('桥接模式 —— 下游路由器 PPPoE 拨号')),
			E('option', { 'value': 'router', 'selected': (vOpMode == 'router') ? 'selected' : null },
				_('路由模式 —— 光猫内部 PPPoE 拨号'))
		]);
		var elBridged = E('input', { 'type': 'checkbox', 'checked': vBridged ? 'checked' : null });
		var elPort25 = E('select', { 'class': 'cbi-input-select' },
			portCand.map(function(p) {
				return E('option', { 'value': p, 'selected': (p == vPort25) ? 'selected' : null }, p);
			}));
		var elVlanEn = E('input', { 'type': 'checkbox', 'checked': vVlanEn ? 'checked' : null });
		var elVlan = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vVlan,
			'placeholder': '3114', 'style': 'width: 8em' });
		var elScheme = E('select', { 'class': 'cbi-input-select' },
			Object.keys(schemeLabels).map(function(k) {
				return E('option', { 'value': k, 'selected': (k == vScheme) ? 'selected' : null },
					schemeLabels[k]);
			}));
		var elMgmtVlan = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vMgmtVlan,
			'placeholder': '2100', 'style': 'width: 8em' });
		var elMgmtIp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vMgmtIp,
			'placeholder': '192.168.9.1' });
		var elMgmtRtr = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vMgmtRtr,
			'placeholder': '192.168.9.254' });
		var elPppUser = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vUser,
			'placeholder': 'user@broadband' });
		var elPppPass = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'value': declared.pppoe_pass || '' });
		var elIpv6 = E('input', { 'type': 'checkbox', 'checked': vIpv6 ? 'checked' : null });

		var blockB = E('div', { 'style': (vScheme == 'B') ? '' : 'display: none' });
		var blockC = E('div', { 'style': (vScheme == 'C') ? '' : 'display: none' });
		var bridgeBlock = E('div', { 'style': (vOpMode == 'bridge') ? '' : 'display: none' });
		var routerBlock = E('div', { 'style': (vOpMode == 'router') ? '' : 'display: none' });

		elScheme.addEventListener('change', function() {
			blockB.style.display = (this.value == 'B') ? '' : 'none';
			blockC.style.display = (this.value == 'C') ? '' : 'none';
		});
		elMode.addEventListener('change', function() {
			bridgeBlock.style.display = (this.value == 'bridge') ? '' : 'none';
			routerBlock.style.display = (this.value == 'router') ? '' : 'none';
		});

		var out = E('pre', { 'class': 'cbi-section', 'style': 'display: none; white-space: pre-wrap; font-size: smaller' });

		var self = this;

		var applyBtn = E('button', {
			'class': 'btn cbi-button cbi-button-apply important',
			'click': ui.createHandlerFn(this, function() {
				var mode = elMode.value;
				var vlanEn = elVlanEn.checked;
				var vlan = elVlan.value.trim();
				var scheme = (mode == 'router') ? 'none' : elScheme.value;
				var mvid = elMgmtVlan.value.trim();
				var mip = elMgmtIp.value.trim();
				var mrtr = elMgmtRtr.value.trim();
				var puser = elPppUser.value.trim();
				var ppass = elPppPass.value;

				var errors = [];
				if (vlanEn && !validVid(vlan))
					errors.push(_('运营商 VLAN 必须是 1..4094。'));
				if (mode == 'router' && !puser)
					errors.push(_('路由模式需要填写 PPPoE 用户名。'));
				if (scheme == 'B') {
					if (!validVid(mvid))
						errors.push(_('管理 VLAN 必须是 1..4094。'));
					else if (vlanEn && mvid == vlan)
						errors.push(_('管理 VLAN 不能与运营商 VLAN 相同。'));
				}
				if (scheme == 'C') {
					if (!ipv4Re.test(mip))
						errors.push(_('管理 IP 需要是 IPv4 地址，如 192.168.9.1。'));
					if (!ipv4Re.test(mrtr))
						errors.push(_('路由器虚拟 IP 需要是 IPv4 地址，如 192.168.9.254。'));
				}
				if (errors.length) {
					ui.showModal(_('输入有误'), [
						E('ul', {}, errors.map(function(e) { return E('li', {}, e); })),
						E('div', { 'class': 'right' },
							E('button', { 'class': 'btn', 'click': ui.hideModal }, _('关闭')))
					]);
					return Promise.resolve();
				}

				uci.set('ponwizard', 'config', 'op_mode', mode);
				uci.set('ponwizard', 'config', 'bridged', elBridged.checked ? '1' : '0');
				uci.set('ponwizard', 'config', 'port25', elPort25.value);
				uci.set('ponwizard', 'config', 'wan_vlan_enabled', vlanEn ? '1' : '0');
				uci.set('ponwizard', 'config', 'wan_vlan', vlan);
				uci.set('ponwizard', 'config', 'mgmt_scheme', scheme);
				uci.set('ponwizard', 'config', 'mgmt_vlan', mvid);
				uci.set('ponwizard', 'config', 'mgmt_ip', mip);
				uci.set('ponwizard', 'config', 'mgmt_router_ip', mrtr);
				uci.set('ponwizard', 'config', 'pppoe_user', puser);
				uci.set('ponwizard', 'config', 'pppoe_pass', ppass);
				uci.set('ponwizard', 'config', 'wan_ipv6', elIpv6.checked ? '1' : '0');

				return uci.save()
					.then(function() { return L.resolveDefault(fs.exec_direct(APPLY, [ 'apply' ]), null); })
					.then(function(output) {
						out.style.display = '';
						dom.content(out, output || _('应用失败 —— 刷新页面重新读取状态。'));
						return self.refresh();
					});
			})
		}, _('保存并应用'));

		blockB.append(
			fieldRow(_('管理 VLAN（方案 B）'), elMgmtVlan,
				_('2.5G 口带 tag、千兆口剥 tag，管理 IP 移到该 VLAN 子接口。路由器侧按 FLASHING.md 6.7.2 配置。')));
		blockC.append(
			fieldRow(_('管理 IP（方案 C）'), elMgmtIp,
				_('挂在 WAN 桥（或其运营商 VLAN 子接口）上的静态 IP，必须用新网段，如 192.168.9.0/24。')),
			fieldRow(_('路由器虚拟 IP（方案 C）'), elMgmtRtr,
				_('唯一允许访问管理端口的源地址；路由器侧 luci-app-ap-modem 插件里填同一个值。')));
		bridgeBlock.append(
			fieldRow(_('桥接 2.5G 口给下游 PPPoE'), elBridged,
				_('建立纯二层桥（光口 + 2.5G 口）并把 WAN 指向它、协议设为「无」。取消勾选不会拆除已有桥。')),
			fieldRow(_('2.5G 口名称'), elPort25,
				_('建桥时使用；已桥接的光猫会自动检测（换板子先在 SSH 里 ip -br link 确认）。')),
			fieldRow(_('管理访问方案'), elScheme,
				_('下游路由器及其设备访问光猫管理页的方式；路由模式下管理页就是 LAN 页，无需选择。')),
			blockB,
			blockC);
		routerBlock.append(
			fieldRow(_('PPPoE 用户名'), elPppUser,
				_('运营商提供的宽带账号；密码明文保存在 /etc/config（与 OpenWrt 一致）。')),
			fieldRow(_('PPPoE 密码'), elPppPass,
				_('留空则沿用已保存的密码（检测到已配置账号时可不重填）。')),
			fieldRow(_('IPv6（DHCPv6）'), elIpv6,
				_('勾选后在 PPPoE 之上建立 wan6（dhcpv6，缺省开启）。')));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('期望配置')),

			fieldRow(_('工作模式'), elMode,
				_('桥接 = 下游路由器拨号（2.5G 口透传）；路由 = 光猫自己拨号，无需下游路由器。')),

			fieldRow(_('运营商 VLAN tag'), [ elVlanEn, ' ', elVlan ],
				vOpMode == 'router'
					? _('OLT 下发的上网业务带 tag 时勾选（如 3114），拨号走 pon0.<VLAN> 子接口。')
					: _('OLT 下发的上网业务带 tag 时勾选（如 3114）；2.5G 侧保持 untagged 给路由器 PPPoE。')),

			bridgeBlock,
			routerBlock,

			E('div', { 'class': 'cbi-page-actions' }, applyBtn),
			out
		]);
	},

	refresh: function() {
		return fetchStatus().then(L.bind(function(st) {
			if (st == null)
				return;
			var c = document.querySelector('#pon-wizard');
			if (!c)
				return;
			dom.content(c.querySelector('#pw-timer-slot'), this.renderTimer(st));
			var sync = c.querySelector('#pw-sync-slot');
			if (sync)
				sync.parentNode.style.display = st.in_sync ? 'none' : '';
		}, this));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
