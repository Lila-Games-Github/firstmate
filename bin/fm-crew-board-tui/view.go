package main

import (
	"fmt"
	"math"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

var (
	green      = lipgloss.Color("#8DFF81")
	yellow     = lipgloss.Color("#F8EF73")
	cyan       = lipgloss.Color("#71E7EF")
	red        = lipgloss.Color("#FF717D")
	muted      = lipgloss.Color("#9AA8A5")
	white      = lipgloss.Color("#E6F2ED")
	background = lipgloss.Color("#080D16")
)

type panelRect struct {
	id                  string
	x, y, width, height int
}

func phaseColor(phase string) lipgloss.Style {
	color := green
	switch phase {
	case "fixing":
		color = red
	case "building":
		color = cyan
	case "testing", "validating":
		color = yellow
	case "ready-to-merge", "done":
		color = green
	case "paused", "blocked", "needs-decision", "failed":
		color = red
	}
	return lipgloss.NewStyle().Foreground(color)
}

func activePhase(phase string) bool {
	switch phase {
	case "investigating", "building", "fixing", "testing", "validating":
		return true
	}
	return false
}

func (m *app) panelCount(spec panelSpec) int { return len(m.items(spec.id)) }

func collapsedHeight(count int) int {
	if count == 0 {
		return 1
	}
	return 3
}

func panelSummary(spec panelSpec, rows []item, width int) string {
	count := len(rows)
	if count == 0 {
		return ansi.Truncate(fmt.Sprintf("  %-18s · empty", spec.title), width, "…")
	}
	first := rows[0].Title
	return ansi.Truncate(fmt.Sprintf("%s  %d  %s", spec.title, count, first), max(1, width), "…")
}

func (m *app) header() string {
	workers := len(m.data.liveWorkers())
	var tabs []string
	for index, name := range pageNames {
		label := fmt.Sprintf("%d %s", index+1, name)
		if count := m.alertCount(index); count > 0 {
			label += fmt.Sprintf(" !%d", count)
		}
		style := lipgloss.NewStyle().Foreground(muted)
		if index == m.page {
			style = lipgloss.NewStyle().Foreground(yellow).Bold(true)
		}
		tabs = append(tabs, style.Render("["+label+"]"))
	}
	left := lipgloss.NewStyle().Foreground(green).Bold(true).Render("FIRSTMATE  //  " + m.data.Home)
	clock := lipgloss.NewStyle().Foreground(yellow).Render(time.Now().Format("2006-01-02 15:04:05"))
	line := left + "   " + clock + "   WORKERS " + fmt.Sprint(workers)
	line = ansi.Truncate(line, max(1, m.width-4), "…")
	content := line + "\n" + strings.Join(tabs, "  ")
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(green).
		Width(max(1, m.width-2)).Height(2).Render(content)
}

func (m *app) renderCompact(spec panelSpec, width int) string {
	rows := m.items(spec.id)
	if len(rows) == 0 {
		return lipgloss.NewStyle().Foreground(muted).Width(width).Render(panelSummary(spec, rows, width))
	}
	border := green
	for _, row := range rows {
		if row.Alert {
			border = red
			break
		}
	}
	content := panelSummary(spec, rows, width-4)
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(border).
		Width(max(1, width-2)).Height(1).Render(content)
}

func (m *app) renderMinimal(spec panelSpec, width int) string {
	return lipgloss.NewStyle().Foreground(muted).Width(width).Render(panelSummary(spec, m.items(spec.id), width))
}

func (m *app) rowLine(id string, row item, index, width int) string {
	selectedIndex, hasSelection := m.selected[id]
	selected := hasSelection && index == selectedIndex
	prefix := "  "
	if selected {
		prefix = "› "
	}
	if id == "workers" && activePhase(row.Status) {
		prefix += m.spinner.View() + " "
	}
	if id == "workers" && !activePhase(row.Status) {
		prefix += "  "
	}
	if m.expanded[id] == index+1 {
		prefix += "▾ "
	} else {
		prefix += "▸ "
	}
	status := row.Status
	if id == "workers" {
		for _, worker := range m.data.liveWorkers() {
			if worker.ID == row.ID {
				status = elapsed(worker.PhaseSince, time.Now()) + "  " + strings.ToUpper(row.Status)
				break
			}
		}
	}
	available := max(1, width-lipgloss.Width(prefix)-lipgloss.Width(status)-2)
	name := ansi.Truncate(row.Title, available, "…")
	spaces := strings.Repeat(" ", max(1, available-lipgloss.Width(name)+1))
	line := prefix + name + spaces + phaseColor(row.Status).Render(status)
	if selected {
		line = lipgloss.NewStyle().Foreground(background).Background(yellow).Render(line)
	}
	return line
}

func (m *app) detail(id string, row item, width int) string {
	var lines []string
	if row.Detail != "" {
		lines = append(lines, row.Detail)
	}
	if row.Link != "" && !strings.Contains(row.Detail, row.Link) {
		lines = append(lines, row.Link)
	}
	if id == "workers" {
		pane := m.peekText[row.ID]
		if pane == "" {
			pane = "Reading worker screen…"
		}
		lines = append(lines, "LIVE SCREEN (read only, via fm-peek.sh)", pane)
	}
	if len(lines) == 0 {
		lines = append(lines, "No further detail")
	}
	var display []string
	for _, line := range strings.Split(strings.Join(lines, "\n"), "\n") {
		display = append(display, lipgloss.NewStyle().Foreground(muted).Render("    "+ansi.Truncate(line, max(1, width-5), "…")))
	}
	return strings.Join(display, "\n")
}

func (m *app) renderFocused(spec panelSpec, width, height int) string {
	rows := m.items(spec.id)
	if len(rows) == 0 || m.collapsed[spec.id] {
		return m.renderCompact(spec, width)
	}
	innerWidth := max(1, width-4)
	innerHeight := max(1, height-4)
	var lines []string
	for index, row := range rows {
		lines = append(lines, m.rowLine(spec.id, row, index, innerWidth))
		if m.expanded[spec.id] == index+1 {
			lines = append(lines, m.detail(spec.id, row, innerWidth))
		}
	}
	view := viewport.New(viewport.WithWidth(innerWidth), viewport.WithHeight(innerHeight))
	view.SoftWrap = true
	view.SetContent(strings.Join(lines, "\n"))
	if selected, ok := m.selected[spec.id]; ok {
		view.SetYOffset(max(0, selected-innerHeight/2))
	}
	title := lipgloss.NewStyle().Foreground(yellow).Bold(true).Render(spec.title)
	if spec.id == "workers" {
		counts := phaseCounts(m.data.liveWorkers())
		var parts []string
		for _, phase := range []string{"fixing", "building", "testing", "ready-to-merge", "paused", "needs-decision"} {
			if counts[phase] > 0 {
				parts = append(parts, fmt.Sprintf("%s %d", strings.ToUpper(phase), counts[phase]))
			}
		}
		if len(parts) > 0 {
			title += "  " + lipgloss.NewStyle().Foreground(cyan).Render(strings.Join(parts, "  "))
		}
	}
	content := ansi.Truncate(title, innerWidth, "…") + "\n" + view.View()
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(yellow).
		Width(max(1, width-2)).Height(max(1, height-2)).Render(content)
}

func (m *app) helpOverlay(width, height int) string {
	lines := []string{
		"VIM KEYS", "j/k rows  h/l panels  gg/G ends",
		"Ctrl-d/u page  Enter/o expand",
		"za/Space collapse  Alt-1..9 select",
		"1/2/3 pages  / filter",
		"i/: note  Esc leave input",
		"q/:q quit  ? close help",
		"Worker screen: fm-peek.sh (read only)",
	}
	text := strings.Join(lines, "\n")
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cyan).
		Foreground(white).Padding(0, 1).Width(max(1, width-2)).Height(max(1, height-2)).Render(text)
}

func (m *app) View() tea.View {
	if m.width < 50 || m.height < 18 {
		view := tea.NewView("Enlarge terminal to at least 50×18 for the crew board. Press q to quit.")
		view.AltScreen = true
		return view
	}
	bodyHeight := max(5, m.height-8)
	list := pages[m.page]
	focus := list[0]
	for _, spec := range list {
		if spec.id == m.focus {
			focus = spec
			break
		}
	}
	m.lastRects = nil
	var body string
	if m.help {
		body = m.helpOverlay(m.width, bodyHeight)
	} else if m.filterActive {
		body = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cyan).
			Width(m.width - 2).Height(bodyHeight - 2).Render("FILTER " + focus.title + "\n" + m.filterInput.View() + "\nEnter apply  ·  Esc cancel")
	} else if m.width >= 100 {
		focusWidth := max(50, min(m.width-28, int(math.Round(float64(m.width)*m.focusSize))))
		rightWidth := m.width - focusWidth
		m.lastRects = append(m.lastRects, panelRect{focus.id, 0, 4, focusWidth, bodyHeight})
		left := m.renderFocused(focus, focusWidth, bodyHeight)
		var summaries []string
		y := 4
		for _, spec := range list {
			if spec.id == focus.id {
				continue
			}
			summary := m.renderCompact(spec, rightWidth)
			summaries = append(summaries, summary)
			m.lastRects = append(m.lastRects, panelRect{spec.id, focusWidth, y, rightWidth, collapsedHeight(m.panelCount(spec))})
			y += collapsedHeight(m.panelCount(spec))
		}
		right := lipgloss.JoinVertical(lipgloss.Left, summaries...)
		body = lipgloss.JoinHorizontal(lipgloss.Top, left, right)
	} else {
		summaryHeight := 0
		for _, spec := range list {
			if spec.id != focus.id {
				summaryHeight += collapsedHeight(m.panelCount(spec))
			}
		}
		minimal := bodyHeight < summaryHeight+5
		if minimal {
			summaryHeight = len(list) - 1
		}
		focusHeight := max(3, bodyHeight-summaryHeight)
		m.lastRects = append(m.lastRects, panelRect{focus.id, 0, 4, m.width, focusHeight})
		var blocks []string
		blocks = append(blocks, m.renderFocused(focus, m.width, focusHeight))
		y := 4 + focusHeight
		for _, spec := range list {
			if spec.id == focus.id {
				continue
			}
			panelHeight := collapsedHeight(m.panelCount(spec))
			if minimal {
				panelHeight = 1
				blocks = append(blocks, m.renderMinimal(spec, m.width))
			} else {
				blocks = append(blocks, m.renderCompact(spec, m.width))
			}
			m.lastRects = append(m.lastRects, panelRect{spec.id, 0, y, m.width, panelHeight})
			y += panelHeight
		}
		body = lipgloss.JoinVertical(lipgloss.Left, blocks...)
	}
	if m.slide > 0.5 {
		body = lipgloss.NewStyle().PaddingLeft(int(math.Round(m.slide))).MaxWidth(m.width).Render(body)
	}
	body = lipgloss.NewStyle().Height(bodyHeight).MaxHeight(bodyHeight).Render(body)
	selected := "all"
	if row := m.focusedItem(); row != nil {
		selected = row.ID
	}
	label := "NOTE [" + selected + "]  "
	m.input.SetWidth(max(8, m.width-4-lipgloss.Width(label)))
	note := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cyan).
		Width(m.width - 2).Height(1).Render(label + m.input.View())
	footer := m.notice
	if footer == "" {
		footer = "j/k rows · h/l panels · Enter expand · / filter · i note · 1/2/3 pages · ? help · q quit"
	}
	footer = lipgloss.NewStyle().Foreground(muted).Render(ansi.Truncate(footer, m.width-2, "…"))
	content := m.header() + "\n" + body + "\n" + note + "\n" + footer
	view := tea.NewView(content)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	view.WindowTitle = "Firstmate crew board"
	return view
}
