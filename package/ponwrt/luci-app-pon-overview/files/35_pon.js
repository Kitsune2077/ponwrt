'use strict';
'require baseclass';
'require fs';
'require uci';

/* Compact PON card for Status -> Overview. Reads the same data as the
 * luci-app-pon status page (ponctl/pondctl), so the exec permissions are
 * already granted by the luci-app-pon rpcd ACL. */

var modeLabels = {
	gpon: _('GPON'),
	xgpon: _('XG-PON'),
	xgspon: _('XGS-PON'),
	'epon-1g': _('EPON 1G/1G'),
	'epon-10g-1g': _('10G-EPON 10G/1G'),
	'epon-10g-10g': _('10G-EPON 10G/10G')
};

var lifecycleLabels = {
	stopped: _('Stopped'),
	'wait-optical-signal': _('Waiting for optical signal'),
	'pma-configured': _('PMA configured'),
	'wait-line-sync': _('Waiting for line synchronization'),
	'protocol-activating': _('Protocol activation in progress'),
	operational: _('Operational'),
	error: _('Error')
};

var syncLabels = {
	'not-applicable': _('Not applicable'),
	hunt: _('Hunt'),
	'pre-sync': _('Pre-sync'),
	'in-sync': _('Synchronized'),
	're-sync': _('Re-synchronizing')
};

var onuStateLabels = {
	O1: _('O1 — Initial'),
	O2_3: _('O2-3 — Serial number'),
	O4: _('O4 — Ranging'),
	O5: _('O5 — Operation'),
	O7: _('O7 — Emergency stop')
};

var mpcpLabels = {
	wait: _('Waiting for discovery'),
	registering: _('Waiting for Discovery Gate'),
	'register-request': _('Register Request sent'),
	'register-pending': _('Register received; ACK pending'),
	registered: _('Registered'),
	denied: _('Registration denied')
};

var authLabels = {
	'not-requested': _('OLT did not request authentication'),
	pending: _('Pending'),
	'not-reported': _('Not reported'),
	'not-authenticated': _('Not authenticated'),
	accepted: _('Accepted'),
	'loid-not-found': _('LOID does not exist'),
	'password-mismatch': _('LOID exists, but the password is incorrect'),
	'loid-conflict': _('LOID is already authenticated by another ONU'),
	'reserved-status': _('Reserved authentication status')
};

function lookup(map, key) {
	return (key != null && key !== '' && map[key]) || key || _('Unknown');
}

function booleanLabel(value) {
	if (value === true || value === 1 || value === '1')
		return _('Yes', 'PON status boolean');
	if (value === false || value === 0 || value === '0')
		return _('No', 'PON status boolean');
	return _('Unknown');
}

function frontendMetric(frontend, field, unit) {
	if (frontend == null || frontend.error)
		return _('Read failed');
	if (frontend[field] == null)
		return _('Not supported');
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

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'style': 'width: 42%' }, label),
		E('td', {}, (value == null || value === '') ? _('Unknown') : String(value))
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
		row(_('Line mode'), lookup(modeLabels, mode || 'none')),
		row(_('Line state'), lookup(lifecycleLabels, line.lifecycle)),
		row(epon ? _('MPCP state') : _('ONU state'),
		    epon ? lookup(mpcpLabels, registration.mpcp_state)
		         : lookup(onuStateLabels, registration.onu_state)),
		row(epon ? _('LLID') : _('ONU-ID'),
		    epon ? (registration.llid_valid === true ? registration.llid : _('Not assigned'))
		         : (registration.onu_id_valid === true ? registration.onu_id : _('Not assigned'))),
		row(_('Optical signal detected'), booleanLabel(line.optical_signal)),
		row(_('Receive optical power'), frontendMetric(frontend, 'rx_power_dbm', 'dBm')),
		row(_('Transmit optical power'), frontendMetric(frontend, 'tx_power_dbm', 'dBm')),
		row(_('Optical frontend temperature'), frontendMetric(frontend, 'temperature_celsius', '°C'))
	];

	if (!epon) {
		rows.push(row(mode === 'gpon' ? _('GTC state') : _('XGTC state'),
		    lookup(syncLabels, line.xgtc_sync)));

		if (omci != null) {
			var olt = [ omci.olt_vendor_id, omci.olt_equipment_id ]
				.filter(function(v) { return v != null && v !== ''; })
				.join(' / ');

			rows.push(
				row(_('OMCI channel online'), booleanLabel(omci.channel_available)),
				row(_('OLT equipment ID'), olt || _('Unknown')),
				row(_('LOID authentication'), lookup(authLabels, omci.authentication_meaning)));
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
					return Promise.resolve({ section: s, error: _('No device configured') });

				return execJSON('/usr/sbin/ponctl', [ '--device', device, 'status', '--json' ])
					.then(function(snapshot) {
						if (snapshot == null || snapshot.schema_version !== 1 || !snapshot.line)
							return { section: s, error: _('Unable to read PON line status') };

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
				rows = [ row(_('Error'), item.error) ];
			else
				rows = lineRows(item, omciByLine[item.section['.name']]);

			if (data.lines.length > 1)
				rows.unshift(row(_('Line'), item.section['.name']));

			return E('table', { 'class': 'table' }, rows);
		});

		nodes.push(E('div', { 'style': 'text-align: right' },
			E('a', {
				'href': L.url('admin/network/pon/status'),
				'class': 'button'
			}, [ _('PON status'), ' »' ])));

		return E('div', { 'id': 'pon_overview_status' }, nodes);
	}
});
