'use strict';
'require view';
'require dom';
'require fs';
'require poll';
'require ui';
'require uci';

/* PON provisioning wizard: bridge the 2.5G port for downstream PPPoE,
 * set the operator VLAN tag, and pick a management-access scheme
 * (FLASHING.md sections 6 / 6.4 / 6.7). The form is prefilled from the
 * DETECTED state reported by pon-wizard-apply, so a modem that already
 * runs scheme B or C (applied by hand or by ponwrt-single-wire.sh) shows
 * the matching options checked. */

var APPLY = '/usr/libexec/pon-wizard-apply';

var schemeLabels = {
	none: _('Disabled (remove applied management access)'),
	A: _('Scheme A — second management cable (no modem-side change)'),
	B: _('Scheme B — management VLAN over the single wire'),
	C: _('Scheme C — untagged management IP + router plugin')
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
	/* detected wins over the stored declaration: a modem already running
	 * scheme B/C (configured manually) must open with those boxes checked */
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
			E('h2', {}, _('PON provisioning wizard')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Bridge the 2.5G port for downstream PPPoE, set the operator VLAN, and choose how the modem management page is reached. Existing configurations are detected automatically.')),
			container
		]);
	},

	renderStatus: function(status) {
		if (status == null)
			return E('div', { 'class': 'cbi-section' },
				E('p', { 'class': 'alert-message warning' },
					_('Unable to read the current state (%s is missing or failed).').format(APPLY)));

		var mgmt;
		switch (status.mgmt.scheme) {
			case 'B':
				mgmt = _('Scheme B (management VLAN %s)').format(status.mgmt.vid);
				break;
			case 'C':
				mgmt = _('Scheme C (%s on %s, only %s allowed)').format(
					status.mgmt.ip, status.mgmt.parent, status.mgmt.router || '?');
				break;
			default:
				mgmt = _('None');
		}

		var row = function(l, v) {
			return E('tr', {}, [
				E('td', { 'style': 'width: 42%' }, l),
				E('td', {}, (v == null || v === '') ? _('Unknown') : String(v))
			]);
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Detected state')),
			E('div', { 'id': 'pw-sync-slot' }, !status.in_sync
				? E('p', { 'class': 'alert-message notice' },
					_('The detected configuration differs from the saved declaration. Saving will reconcile the system to the form below.'))
				: E([])),
			E('table', { 'class': 'table' }, [
				row(_('Bridged for downstream PPPoE'),
					status.bridged ? _('yes (%s = %s + %s)').format(status.pon_bridge, status.pon_port, status.port25) : _('no')),
				row(_('Operator VLAN'), status.isp_vid || _('none (untagged)')),
				row(_('Management access'), mgmt)
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
			E('strong', {}, _('Rollback armed: ')), ' ',
			_('changes were applied but not confirmed yet; they will be reverted in %s:%s.').format(mm, ss), ' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-apply important',
				'click': ui.createHandlerFn(this, function() {
					return fs.exec_direct(APPLY, [ 'confirm' ]).then(L.bind(this.refresh, this));
				})
			}, _('Keep configuration')), ' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function() {
					return fs.exec_direct(APPLY, [ 'revert' ]).then(L.bind(this.refresh, this));
				})
			}, _('Revert now'))
		]);
	},

	renderForm: function(status, declared) {
		var det = status || {};
		var detMgmt = det.mgmt || { scheme: 'none' };

		var vBridged = !!(det.bridged || effective(null, declared, 'bridged'));
		var vPort25 = det.port25 || (declared.port25 != null && declared.port25 !== '' ? declared.port25 : 'lan1');
		var vVlanEn = !!(det.isp_vid || effective(null, declared, 'wan_vlan_enabled'));
		var vVlan = det.isp_vid || declared.wan_vlan || '';
		var vScheme = (detMgmt.scheme != 'none') ? detMgmt.scheme
			: (declared.mgmt_scheme != null ? declared.mgmt_scheme : 'none');
		var vMgmtVlan = detMgmt.vid || declared.mgmt_vlan || '2100';
		var vMgmtIp = detMgmt.ip || declared.mgmt_ip || '192.168.9.1';
		var vMgmtRtr = detMgmt.router || declared.mgmt_router_ip || '192.168.9.254';

		/* port candidates: detected GbE ports + detected/declared 2.5G port */
		var portCand = (det.gbe_ports || []).slice();
		[ vPort25, 'lan1' ].forEach(function(p) {
			if (p && portCand.indexOf(p) < 0)
				portCand.push(p);
		});
		portCand.sort();

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

		var blockB = E('div', { 'style': (vScheme == 'B') ? '' : 'display: none' });
		var blockC = E('div', { 'style': (vScheme == 'C') ? '' : 'display: none' });

		elScheme.addEventListener('change', function() {
			blockB.style.display = (this.value == 'B') ? '' : 'none';
			blockC.style.display = (this.value == 'C') ? '' : 'none';
		});

		var out = E('pre', { 'class': 'cbi-section', 'style': 'display: none; white-space: pre-wrap; font-size: smaller' });

		var self = this;

		var applyBtn = E('button', {
			'class': 'btn cbi-button cbi-button-apply important',
			'click': ui.createHandlerFn(this, function() {
				var vlanEn = elVlanEn.checked;
				var vlan = elVlan.value.trim();
				var scheme = elScheme.value;
				var mvid = elMgmtVlan.value.trim();
				var mip = elMgmtIp.value.trim();
				var mrtr = elMgmtRtr.value.trim();

				var errors = [];
				if (vlanEn && !validVid(vlan))
					errors.push(_('Operator VLAN must be 1..4094.'));
				if (scheme == 'B') {
					if (!validVid(mvid))
						errors.push(_('Management VLAN must be 1..4094.'));
					else if (vlanEn && mvid == vlan)
						errors.push(_('Management VLAN must differ from the operator VLAN.'));
				}
				if (scheme == 'C') {
					if (!ipv4Re.test(mip))
						errors.push(_('Management IP must be an IPv4 address, e.g. 192.168.9.1.'));
					if (!ipv4Re.test(mrtr))
						errors.push(_('Router virtual IP must be an IPv4 address, e.g. 192.168.9.254.'));
				}
				if (errors.length) {
					ui.showModal(_('Invalid input'), [
						E('ul', {}, errors.map(function(e) { return E('li', {}, e); })),
						E('div', { 'class': 'right' },
							E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Dismiss')))
					]);
					return Promise.resolve();
				}

				uci.set('ponwizard', 'config', 'bridged', elBridged.checked ? '1' : '0');
				uci.set('ponwizard', 'config', 'port25', elPort25.value);
				uci.set('ponwizard', 'config', 'wan_vlan_enabled', vlanEn ? '1' : '0');
				uci.set('ponwizard', 'config', 'wan_vlan', vlan);
				uci.set('ponwizard', 'config', 'mgmt_scheme', scheme);
				uci.set('ponwizard', 'config', 'mgmt_vlan', mvid);
				uci.set('ponwizard', 'config', 'mgmt_ip', mip);
				uci.set('ponwizard', 'config', 'mgmt_router_ip', mrtr);

				return uci.save()
					.then(function() { return L.resolveDefault(fs.exec_direct(APPLY, [ 'apply' ]), null); })
					.then(function(output) {
						out.style.display = '';
						dom.content(out, output || _('Apply failed — refresh the page to re-read the state.'));
						return self.refresh();
					});
			})
		}, _('Save and apply'));

		blockB.append(
			fieldRow(_('Management VLAN (scheme B)'), elMgmtVlan,
				_('Tagged on the 2.5G port, untagged on the GbE ports; the management IP moves to the VLAN sub-interface. Configure the router side per FLASHING.md 6.7.2.')));
		blockC.append(
			fieldRow(_('Management IP (scheme C)'), elMgmtIp,
				_('Static IP on the WAN bridge (or its operator-VLAN sub-interface), must be a fresh subnet, e.g. 192.168.9.0/24.')),
			fieldRow(_('Router virtual IP (scheme C)'), elMgmtRtr,
				_('The only source address allowed to reach the management ports; configure the same value in the luci-app-ap-modem plugin on the router.')));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Desired configuration')),

			fieldRow(_('Bridge 2.5G port for PPPoE'), elBridged,
				_('Creates the pure L2 bridge (PON port + 2.5G port) and points WAN at it with no protocol. Unchecking does not tear the bridge down.')),
			fieldRow(_('2.5G port name'), elPort25,
				_('Used when creating the bridge; auto-detected on bridged modems (verify with "ip -br link" on a new board).')),
			fieldRow(_('Operator VLAN tag'), [ elVlanEn, ' ', elVlan ],
				_('Enable when the OLT delivers the internet service tagged (e.g. 3114); the 2.5G side stays untagged for the router PPPoE.')),
			fieldRow(_('Management access scheme'), elScheme),

			blockB,
			blockC,

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
