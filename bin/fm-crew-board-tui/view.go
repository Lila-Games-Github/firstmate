package main

import (
	"fmt"
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
	case "paused", "blocked", "needs-decision", "failed", "unauthorized", "offline", "locked":
		color = red
	case "unavailable", "auth_required", "idle", "not yet today":
		color = muted
	case "due now":
		color = yellow
	}
	switch {
	case strings.HasPrefix(phase, "running "):
		color = cyan
	case strings.HasPrefix(phase, "waiting #"):
		color = muted
	}
	return lipgloss.NewStyle().Foreground(color)
}

func activePhase(phase string) bool {
	switch phase {
	case "investigating", "building", "fixing", "testing", "validating", "working":
		return true
	}
	return false
}

const summaryCardHeight = 4

func panelSummary(spec panelSpec, rows []item, width int) string {
	rows = withoutSections(rows)
	nouns := map[string]string{
		"alerts": "alerts", "workers": "workers", "ready": "ready",
		"feed": "updates", "phones": "connected", "test_queue": "queued", "landings": "landed",
		"builds": "builds", "routines": "routines", "bugs": "bugs", "backlog": "tasks",
		"allowance": "providers", "full_questions": "questions",
	}
	count := "none"
	latest := "latest: none"
	if len(rows) > 0 {
		count = fmt.Sprintf("%d %s", len(rows), nouns[spec.id])
		if spec.id == "workers" {
			groups := map[string]int{}
			var order []string
			for _, row := range rows {
				if groups[row.Group] == 0 {
					order = append(order, row.Group)
				}
				groups[row.Group]++
			}
			var parts []string
			for _, group := range order {
				parts = append(parts, fmt.Sprintf("%s %d", group, groups[group]))
			}
			count += " (" + strings.Join(parts, ", ") + ")"
		}
		if spec.id == "phones" {
			connected, cached, unavailable := 0, 0, 0
			for _, row := range rows {
				switch row.ADB {
				case "device":
					connected++
				case "unavailable":
					unavailable++
				case "":
					cached++
				}
			}
			count = fmt.Sprintf("%d %s", connected, nouns[spec.id])
			if cached > 0 {
				count += fmt.Sprintf(" (%d cached)", cached)
			}
			if unavailable > 0 {
				count = "unavailable"
			}
		}
		if spec.id == "allowance" {
			for _, row := range rows {
				if row.Quota == "unavailable" {
					count = "unavailable"
					break
				}
			}
		}
		latest = "latest: " + rows[len(rows)-1].Title
	}
	first := ansi.Truncate(spec.title+"  "+count, max(1, width), "…")
	return first + "\n" + ansi.Truncate(latest, max(1, width), "…")
}

func withoutSections(rows []item) []item {
	kept := make([]item, 0, len(rows))
	for _, row := range rows {
		if row.Status != "section" {
			kept = append(kept, row)
		}
	}
	return kept
}

func (m *app) header() string {
	workers := len(m.data.liveWorkers())
	var tabs []string
	for index, name := range pageNames {
		label := fmt.Sprintf("%d %s", index+1, name)
		style := lipgloss.NewStyle().Foreground(muted)
		if index == m.page {
			style = lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true)
		}
		tab := style.Render(" " + label + " ")
		if count := m.alertCount(index); count > 0 {
			tab += " " + lipgloss.NewStyle().Foreground(background).Background(red).Bold(true).
				Render(fmt.Sprintf(" %d ", count))
		}
		if count := len(withoutSections(m.data.Panels.FullQuestions)); index == 3 && count > 0 {
			tab += " " + lipgloss.NewStyle().Foreground(background).Background(cyan).Bold(true).
				Render(fmt.Sprintf(" %d ", count))
		}
		tabs = append(tabs, tab)
	}
	brand := "FIRSTMATE"
	if home := strings.TrimSpace(m.data.Home); home != "" && !strings.EqualFold(home, brand) {
		brand += "  //  " + home
	}
	left := lipgloss.NewStyle().Foreground(green).Bold(true).Render(brand)
	clock := lipgloss.NewStyle().Foreground(muted).Render(time.Now().Format("15:04:05"))
	line := left + "   " + clock + "   WORKERS " + fmt.Sprint(workers)
	line = ansi.Truncate(line, max(1, m.width-4), "…")
	tabWidth := max(1, m.width-4)
	prefix := strings.Join(tabs[:m.page+1], "  ")
	if lipgloss.Width(prefix) > tabWidth {
		tabs = tabs[m.page:]
	}
	content := line + "\n" + ansi.Truncate(strings.Join(tabs, "  "), tabWidth, "…")
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(green).
		Width(max(1, m.width-2)).Height(2).Render(content)
}

func (m *app) subTabs(width int) string {
	var tabs []string
	for _, spec := range pages[m.page][m.subTabStart(width):] {
		tabs = append(tabs, m.subTab(spec))
	}
	return ansi.Truncate(strings.Join(tabs, " "), width, "…")
}

func (m *app) subTabStart(width int) int {
	position := 0
	for index, spec := range pages[m.page] {
		position += lipgloss.Width(m.subTab(spec))
		if spec.id == m.focus && position > width {
			return index
		}
		position++
	}
	return 0
}

func (m *app) subTab(spec panelSpec) string {
	style := lipgloss.NewStyle().Foreground(muted)
	if spec.id == m.focus {
		style = lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true)
	}
	tab := style.Render(" " + spec.title + " ")
	count := 0
	for _, row := range m.items(spec.id) {
		if row.Alert {
			count++
		}
	}
	if count > 0 {
		tab += lipgloss.NewStyle().Foreground(background).Background(red).Bold(true).
			Render(fmt.Sprintf(" %d ", count))
	}
	return tab
}

func (m *app) subTabAt(x, width int) string {
	if x < 0 || x >= width {
		return ""
	}
	position := 0
	for _, spec := range pages[m.page][m.subTabStart(width):] {
		end := position + lipgloss.Width(m.subTab(spec))
		if x >= position && x < end {
			return spec.id
		}
		position = end + 1
	}
	return ""
}

func (m *app) renderCompact(spec panelSpec, width int) string {
	rows := m.items(spec.id)
	border := green
	if len(rows) == 0 {
		border = muted
	}
	if spec.id == m.focus {
		border = yellow
	}
	for _, row := range rows {
		if row.Alert {
			border = red
			break
		}
	}
	parts := strings.SplitN(panelSummary(spec, rows, width-4), "\n", 2)
	content := lipgloss.NewStyle().Foreground(border).Bold(true).Render(parts[0]) + "\n" +
		lipgloss.NewStyle().Foreground(muted).Render(parts[1])
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(border).
		Width(max(1, width-2)).Height(2).Render(content)
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
		if id == "full_questions" || id == "backlog" {
			line = strings.ReplaceAll(line, "**", "")
			for _, wrapped := range strings.Split(ansi.Wrap(line, max(1, width-4), ""), "\n") {
				display = append(display, lipgloss.NewStyle().Foreground(muted).Render("    "+wrapped))
			}
		} else {
			display = append(display, lipgloss.NewStyle().Foreground(muted).Render("    "+ansi.Truncate(line, max(1, width-5), "…")))
		}
	}
	return strings.Join(display, "\n")
}

func (m *app) panelLines(spec panelSpec, width int) ([]string, []int) {
	var lines []string
	var owners []int
	rows := m.items(spec.id)
	groups := map[string]int{}
	if spec.id == "workers" {
		for _, row := range rows {
			groups[row.Group]++
		}
	}
	lastGroup := ""
	for index, row := range rows {
		if row.Status == "section" {
			if len(lines) > 0 {
				lines = append(lines, "")
				owners = append(owners, -1)
			}
			heading := lipgloss.NewStyle().Foreground(cyan).Bold(true).Render(ansi.Truncate(row.Title, width, "…"))
			rule := lipgloss.NewStyle().Foreground(muted).Render(strings.Repeat("─", max(1, width)))
			lines = append(lines, heading, rule)
			owners = append(owners, -1, -1)
			continue
		}
		if spec.id == "workers" && (index == 0 || row.Group != lastGroup) {
			noun := "workers"
			if groups[row.Group] == 1 {
				noun = "worker"
			}
			heading := fmt.Sprintf("%s  %d %s", strings.ToUpper(row.Group), groups[row.Group], noun)
			lines = append(lines, lipgloss.NewStyle().Foreground(cyan).Bold(true).Render(ansi.Truncate(heading, width, "…")))
			owners = append(owners, -1)
		}
		lastGroup = row.Group
		lines = append(lines, m.rowLine(spec.id, row, index, width))
		owners = append(owners, index)
		if m.expanded[spec.id] == index+1 || m.readingQuestion(spec.id, index) {
			for _, detail := range strings.Split(m.detail(spec.id, row, width), "\n") {
				lines = append(lines, detail)
				owners = append(owners, index)
			}
		}
	}
	return lines, owners
}

// readingQuestion reports whether a captain question row is under the cursor,
// which shows its full text without Enter.
func (m *app) readingQuestion(id string, index int) bool {
	selected, ok := m.selected[id]
	return id == "full_questions" && ok && selected == index
}

func (m *app) panelOffset(spec panelSpec, width, height int, owners []int) int {
	viewHeight := max(1, height-5)
	selectedLine := 0
	if selected, ok := m.selected[spec.id]; ok {
		for line, owner := range owners {
			if owner == selected {
				selectedLine = line
				break
			}
		}
	}
	if selected, ok := m.selected[spec.id]; ok && m.readingQuestion(spec.id, selected) {
		return min(max(0, len(owners)-viewHeight), max(0, selectedLine+m.scrollOffset[spec.id]))
	}
	return min(max(0, len(owners)-viewHeight), max(0, selectedLine-viewHeight/2+m.scrollOffset[spec.id]))
}

func (m *app) renderFocused(spec panelSpec, width, height int) string {
	rows := m.items(spec.id)
	innerWidth := max(1, width-4)
	innerHeight := max(1, height-5)
	lines, owners := m.panelLines(spec, innerWidth)
	if len(rows) == 0 {
		message := "No items to show"
		switch spec.id {
		case "phones":
			message = "No phones connected"
		case "landings":
			message = "Nothing landed today"
		case "full_questions":
			message = "No captain questions"
		case "alerts":
			message = "Nothing needs your attention. ALERTS shows only monitoring outages, blocked or failed workers, decisions not yet raised with you, and unavailable phones."
		case "ready":
			message = "Nothing is waiting on you. READY FOR YOU shows green PRs to merge, finished local branches to land, unread investigation reports, and previews you asked to see."
		case "test_queue":
			message = "No full suite or phone test is running or waiting"
		case "routines":
			message = "No daily routines are registered in this home"
		}
		lines = strings.Split(lipgloss.NewStyle().Foreground(muted).Render(ansi.Wrap(message, innerWidth, "")), "\n")
	} else if m.collapsed[spec.id] {
		lines = []string{lipgloss.NewStyle().Foreground(muted).Render("Panel collapsed")}
		owners = nil
	}
	view := viewport.New(viewport.WithWidth(innerWidth), viewport.WithHeight(innerHeight))
	view.SoftWrap = false
	view.SetContent(strings.Join(lines, "\n"))
	view.SetYOffset(m.panelOffset(spec, innerWidth, height, owners))
	accent := yellow
	title := lipgloss.NewStyle().Foreground(accent).Bold(true).Render(spec.title)
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
	if m.slide > 0 {
		shifted := make([]string, 0, len(lines)+2)
		for _, line := range strings.Split(content, "\n") {
			if m.slideDirection > 0 {
				shifted = append(shifted, strings.Repeat(" ", m.slide)+ansi.Truncate(line, max(1, innerWidth-m.slide), ""))
			} else {
				shifted = append(shifted, ansi.Cut(line, m.slide, innerWidth+m.slide))
			}
		}
		content = strings.Join(shifted, "\n")
	}
	content = m.subTabs(innerWidth) + "\n" + content
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(accent).
		Width(max(1, width-2)).Height(max(1, height-2)).Render(content)
}

func (m *app) helpOverlay(width, height int) string {
	lines := []string{
		"VIM KEYS", "j/k rows within the panel  h/l sub-tabs",
		"Tab cycles  Ctrl-d/u rows",
		"Enter/o expand  O focus selected worker pane",
		"za/Space collapse  Alt-1..9 select",
		"1/2/3/4 pages  / filter",
		"Ctrl-f/b scroll detail  r reply to question  i/: note",
		"q/:q quit  ? close help",
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
		focusWidth := max(50, min(m.width-28, m.width*68/100))
		if m.page == 3 {
			focusWidth = m.width
		}
		summaryWidth := m.width - focusWidth
		m.lastRects = append(m.lastRects, panelRect{focus.id, 0, 4, focusWidth, bodyHeight})
		left := m.renderFocused(focus, focusWidth, bodyHeight)
		var summaries []string
		y := 4
		for _, spec := range list {
			if m.page == 3 || y+summaryCardHeight > 4+bodyHeight {
				break
			}
			summary := m.renderCompact(spec, summaryWidth)
			summaries = append(summaries, summary)
			if spec.id != focus.id {
				m.lastRects = append(m.lastRects, panelRect{spec.id, focusWidth, y, summaryWidth, summaryCardHeight})
			}
			y += summaryCardHeight
		}
		right := lipgloss.JoinVertical(lipgloss.Left, summaries...)
		body = left
		if m.page != 3 {
			body = lipgloss.JoinHorizontal(lipgloss.Top, left, right)
		}
	} else {
		summaryHeight := 0
		for range list {
			if m.page != 3 {
				summaryHeight += summaryCardHeight
			}
		}
		minimal := bodyHeight < summaryHeight+5
		if minimal {
			summaryHeight = 0
		}
		focusHeight := max(3, bodyHeight-summaryHeight)
		m.lastRects = append(m.lastRects, panelRect{focus.id, 0, 4, m.width, focusHeight})
		var blocks []string
		blocks = append(blocks, m.renderFocused(focus, m.width, focusHeight))
		y := 4 + focusHeight
		for _, spec := range list {
			if m.page == 3 || minimal {
				break
			}
			panelHeight := summaryCardHeight
			blocks = append(blocks, m.renderCompact(spec, m.width))
			if spec.id != focus.id {
				m.lastRects = append(m.lastRects, panelRect{spec.id, 0, y, m.width, panelHeight})
			}
			y += panelHeight
		}
		body = lipgloss.JoinVertical(lipgloss.Left, blocks...)
	}
	body = lipgloss.NewStyle().Height(bodyHeight).MaxHeight(bodyHeight).Render(body)
	selected := "all"
	if row := m.focusedItem(); row != nil {
		selected = row.ID
	}
	reply := m.selectedQuestion()
	if m.inputActive {
		reply = m.replyTarget
	}
	label := "NOTE [" + selected + "] i: message firstmate  "
	if reply != nil {
		label = "REPLY [" + ansi.Truncate(questionLabel(reply.Title), 16, "…") + "] r/i: answer  "
	}
	m.input.SetWidth(max(8, m.width-8-lipgloss.Width(label)))
	note := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cyan).
		Width(m.width - 2).Height(1).Render(label + m.input.View())
	footer := m.notice
	if footer == "" {
		footer = "4 questions · j/k rows · h/l sub-tabs · Enter expand · r reply · i note · ? help · q quit"
	}
	footer = lipgloss.NewStyle().Foreground(muted).Render(ansi.Truncate(footer, m.width-2, "…"))
	content := m.header() + "\n" + body + "\n" + note + "\n" + footer
	view := tea.NewView(content)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	view.WindowTitle = "Firstmate crew board"
	return view
}
