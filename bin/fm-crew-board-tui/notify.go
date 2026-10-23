package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// An alert is a notification: it has a stable id derived from its source
// record (nid) and a signature of what is wrong (sig). Viewing it records the
// signature as seen, so it recedes until the signature changes; clearing its
// cause drops the record, so a recurrence is new again.

func seenFile(state string) string { return filepath.Join(state, ".crew-board-alerts-seen.json") }

func loadSeen(state string) map[string]string {
	seen := map[string]string{}
	if state == "" {
		return seen
	}
	if raw, err := os.ReadFile(seenFile(state)); err == nil {
		if json.Unmarshal(raw, &seen) != nil || seen == nil {
			seen = map[string]string{}
		}
	}
	return seen
}

func (m *app) saveSeen() {
	if m.paths.State == "" {
		return
	}
	raw, err := json.Marshal(m.seen)
	if err != nil {
		return
	}
	temp := seenFile(m.paths.State) + ".tmp"
	if os.WriteFile(temp, raw, 0600) == nil {
		_ = os.Rename(temp, seenFile(m.paths.State))
	}
}

func alertKey(row item) (string, string) {
	if row.Nid != "" {
		return row.Nid, row.Sig
	}
	return "alert:" + row.Title, row.Status
}

// isNew reports whether an alert row still needs the product owner's eyes.
func (m *app) isNew(row item) bool {
	if !row.Alert {
		return false
	}
	nid, sig := alertKey(row)
	seen, ok := m.seen[nid]
	return !ok || seen != sig
}

func (m *app) newAlerts() []item {
	var rows []item
	for _, row := range m.data.Panels.Alerts {
		if m.isNew(row) {
			rows = append(rows, row)
		}
	}
	return rows
}

func (m *app) openRailRow(row item) {
	m.railDetail = &row
	m.railDetailOffset = 0
	if row.Alert {
		nid, sig := alertKey(row)
		m.seen[nid] = sig
		m.saveSeen()
	}
}

// markViewed records the alert the product owner has selected or opened.
func (m *app) markViewed() {
	if m.page != 0 || m.focus != "alerts" {
		return
	}
	rows := m.items("alerts")
	changed := false
	for _, index := range []int{m.selected["alerts"], m.expanded["alerts"] - 1} {
		if _, selected := m.selected["alerts"]; index == m.selected["alerts"] && !selected {
			continue
		}
		if index < 0 || index >= len(rows) || !rows[index].Alert {
			continue
		}
		nid, sig := alertKey(rows[index])
		if m.seen[nid] != sig {
			m.seen[nid] = sig
			changed = true
		}
	}
	if changed {
		m.saveSeen()
	}
}

// pruneSeen forgets alerts whose cause has cleared.
func (m *app) pruneSeen() {
	live := map[string]bool{}
	for _, row := range m.data.Panels.Alerts {
		nid, _ := alertKey(row)
		live[nid] = true
	}
	changed := false
	for nid := range m.seen {
		if !live[nid] {
			delete(m.seen, nid)
			changed = true
		}
	}
	if changed {
		m.saveSeen()
	}
}
