package main

import (
	"fmt"
	"strings"
	"time"

	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/harmonica"
)

type panelSpec struct{ id, title string }

var pages = [][]panelSpec{
	{{"alerts", "ALERTS"}, {"workers", "WORKERS"}, {"questions", "WAITING ON YOU"},
		{"ready", "READY FOR YOU"}, {"feed", "FEED"}},
	{{"phones", "PHONES"}, {"test_queue", "TEST QUEUE"}, {"landings", "TODAY'S LANDINGS"},
		{"builds", "BUILDS"}, {"routines", "DAILY ROUTINES"}},
	{{"bugs", "ROCKETBOARD BUGS"}, {"backlog", "BACKLOG"}, {"allowance", "AI ALLOWANCE"}},
	{{"full_questions", "CAPTAIN QUESTIONS"}, {"full_backlog", "BACKLOG"}},
}

var pageNames = []string{"NOW", "TESTING", "PLANNING", "QUESTIONS"}

type tickMsg time.Time
type motionMsg time.Time
type refreshedMsg struct {
	data board
	feed []item
	err  error
}
type peekMsg struct {
	id, text string
	err      error
}
type noteMsg struct{ err error }
type focusMsg struct {
	text string
	err  error
}

type app struct {
	paths                    paths
	data                     board
	feed                     []item
	width, height            int
	page                     int
	focus                    string
	selected                 map[string]int
	expanded                 map[string]int
	collapsed                map[string]bool
	filters                  map[string]string
	peekText                 map[string]string
	scrollOffset             map[string]int
	peekLoading              string
	input                    textinput.Model
	inputActive              bool
	filterInput              textinput.Model
	filterActive             bool
	commandMode              bool
	help                     bool
	pendingG, pendingZ       bool
	spinner                  spinner.Model
	notice                   string
	lastRefresh              time.Time
	refreshing               bool
	spring                   harmonica.Spring
	focusSize, focusVelocity float64
	slide, slideVelocity     float64
	animating                bool
	lastRects                []panelRect
}

func newApp(p paths, data board, feed []item) *app {
	input := textinput.New()
	input.Placeholder = "Type note; Enter sends"
	input.CharLimit = 1000
	input.SetWidth(50)
	filter := textinput.New()
	filter.Placeholder = "Filter focused panel"
	filter.CharLimit = 200
	filter.SetWidth(50)
	return &app{
		paths: p, data: data, feed: feed, page: 0, focus: "workers",
		selected: map[string]int{}, expanded: map[string]int{}, collapsed: map[string]bool{},
		filters: map[string]string{}, peekText: map[string]string{}, scrollOffset: map[string]int{},
		input: input, filterInput: filter, spinner: spinner.New(spinner.WithSpinner(spinner.MiniDot)),
		spring:    harmonica.NewSpring(harmonica.FPS(30), 8, 0.8),
		focusSize: 0.68,
	}
}

func (m *app) Init() tea.Cmd {
	return tea.Batch(tick(), func() tea.Msg { return m.spinner.Tick() })
}
func tick() tea.Cmd { return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) }) }
func motionTick() tea.Cmd {
	return tea.Tick(time.Second/30, func(t time.Time) tea.Msg { return motionMsg(t) })
}

func (m *app) refreshCmd() tea.Cmd {
	p := m.paths
	return func() tea.Msg { data, feed, err := p.refresh(); return refreshedMsg{data, feed, err} }
}
func (m *app) peekCmd(id string) tea.Cmd {
	p := m.paths
	return func() tea.Msg { text, err := p.peek(id); return peekMsg{id, text, err} }
}
func (m *app) noteCmd(text string, selected *item) tea.Cmd {
	p := m.paths
	return func() tea.Msg { return noteMsg{p.sendNote(text, selected)} }
}
func (m *app) focusCmd(id string) tea.Cmd {
	p := m.paths
	return func() tea.Msg { text, err := p.focusWorker(id); return focusMsg{text, err} }
}

func (m *app) rawItems(id string) []item {
	switch id {
	case "alerts":
		return m.data.Panels.Alerts
	case "questions":
		return m.data.Panels.Questions
	case "full_questions":
		return m.data.Panels.FullQuestions
	case "full_backlog":
		return m.data.Panels.FullBacklog
	case "ready":
		return m.data.Panels.Ready
	case "phones":
		return m.data.Panels.Phones
	case "test_queue":
		return m.data.Panels.TestQueue
	case "landings":
		return m.data.Panels.Landings
	case "builds":
		return m.data.Panels.Builds
	case "routines":
		return m.data.Panels.Routines
	case "bugs":
		return m.data.Panels.Bugs
	case "allowance":
		return m.data.Panels.Allowance
	case "feed":
		return m.feed
	case "backlog":
		back := m.data.Panels.Backlog
		count := func(value *int) string {
			if value == nil {
				return "?"
			}
			return fmt.Sprintf("%d", *value)
		}
		rows := []item{{ID: "counts", Title: fmt.Sprintf("In flight %s  /  Queued %s", count(back.InFlight), count(back.Queued)),
			Detail: "Next up from fm-tasks-axi.sh", Status: back.Source}}
		return append(rows, back.Next...)
	case "workers":
		workers := m.data.liveWorkers()
		rows := make([]item, 0, len(workers))
		for _, worker := range workers {
			detail := worker.Note
			if worker.PRURL != "" {
				detail += "\nPR: " + worker.PRURL
			}
			rows = append(rows, item{ID: worker.ID, Title: worker.Project + " / " + worker.Title,
				Detail: strings.TrimSpace(detail), Status: worker.Phase, Link: worker.PRURL})
		}
		return rows
	}
	return nil
}

func (m *app) items(id string) []item {
	rows := m.rawItems(id)
	query := strings.ToLower(strings.TrimSpace(m.filters[id]))
	if query == "" {
		return rows
	}
	filtered := make([]item, 0, len(rows))
	for _, row := range rows {
		if strings.Contains(strings.ToLower(row.Title+" "+row.Detail+" "+row.Status), query) {
			filtered = append(filtered, row)
		}
	}
	return filtered
}

func (m *app) focusedItem() *item {
	index, ok := m.selected[m.focus]
	rows := m.items(m.focus)
	if !ok || index < 0 || index >= len(rows) {
		return nil
	}
	selected := rows[index]
	return &selected
}

func (m *app) alertCount(page int) int {
	count := 0
	for _, spec := range pages[page] {
		for _, row := range m.rawItems(spec.id) {
			if row.Alert {
				count++
			}
		}
	}
	return count
}

func (m *app) setPage(page int) {
	if page == m.page || page < 0 || page >= len(pages) {
		return
	}
	m.page = page
	m.focus = pages[page][0].id
	if page == 0 {
		m.focus = "workers"
	}
	m.beginMotion()
}

func (m *app) beginMotion() {
	m.focusSize = 0.48
	m.focusVelocity = 0
	m.slide = 6
	m.slideVelocity = 0
	m.animating = true
}

func (m *app) changeFocus(step int) {
	list := pages[m.page]
	index := 0
	for i, panel := range list {
		if panel.id == m.focus {
			index = i
			break
		}
	}
	index = (index + step + len(list)) % len(list)
	m.focus = list[index].id
	m.beginMotion()
}

// moveFocusSpatial follows the panel positions currently shown on screen.
func (m *app) moveFocusSpatial(dx, dy int) {
	if len(m.lastRects) == 0 {
		_ = m.View()
	}
	var current panelRect
	found := false
	for _, rect := range m.lastRects {
		if rect.id == m.focus {
			current, found = rect, true
			break
		}
	}
	if !found {
		return
	}
	anchorY := current.y + 1 + m.selected[m.focus]
	best, bestDistance := "", int(^uint(0)>>1)
	for _, rect := range m.lastRects {
		if rect.id == m.focus {
			continue
		}
		gap, offset := 0, 0
		switch {
		case dx > 0:
			gap = rect.x - (current.x + current.width)
			offset = absInt(2*rect.y + rect.height - 2*anchorY)
		case dx < 0:
			gap = current.x - (rect.x + rect.width)
			offset = absInt(2*rect.y + rect.height - 2*anchorY)
		case dy > 0:
			gap = rect.y - (current.y + current.height)
			offset = absInt(2*rect.x + rect.width - 2*current.x - current.width)
		case dy < 0:
			gap = current.y - (rect.y + rect.height)
			offset = absInt(2*rect.x + rect.width - 2*current.x - current.width)
		}
		if gap < 0 {
			continue
		}
		distance := gap*1000 + offset
		if distance < bestDistance {
			best, bestDistance = rect.id, distance
		}
	}
	if best != "" {
		m.focus = best
		m.beginMotion()
	}
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func (m *app) moveSelection(step int) {
	rows := m.items(m.focus)
	if len(rows) == 0 {
		m.moveFocusSpatial(0, step)
		return
	}
	index, ok := m.selected[m.focus]
	if !ok {
		if step < 0 {
			index = len(rows) - 1
		} else {
			index = 0
		}
	} else {
		if index+step < 0 || index+step >= len(rows) {
			m.moveFocusSpatial(0, step)
			return
		}
		index = max(0, min(len(rows)-1, index+step))
	}
	m.selected[m.focus] = index
	m.scrollOffset[m.focus] = 0
}

func (m *app) expandSelected() tea.Cmd {
	row := m.focusedItem()
	if row == nil {
		m.moveSelection(1)
		row = m.focusedItem()
	}
	if row == nil {
		return nil
	}
	if row.Status == "section" {
		return nil
	}
	index := m.selected[m.focus]
	if m.expanded[m.focus] == index+1 {
		delete(m.expanded, m.focus)
		return nil
	}
	m.expanded[m.focus] = index + 1
	m.scrollOffset[m.focus] = 0
	if m.focus == "workers" {
		m.peekLoading = row.ID
		return m.peekCmd(row.ID)
	}
	return nil
}

func (m *app) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.input.SetWidth(max(10, msg.Width-12))
		m.filterInput.SetWidth(max(10, msg.Width-12))
	case tickMsg:
		commands := []tea.Cmd{tick()}
		if !m.refreshing && time.Since(m.lastRefresh) >= 2*time.Second {
			m.refreshing = true
			m.lastRefresh = time.Now()
			commands = append(commands, m.refreshCmd())
		}
		if index := m.expanded["workers"] - 1; m.page == 0 && m.focus == "workers" && index >= 0 {
			rows := m.items("workers")
			if index < len(rows) && m.peekLoading == "" {
				m.peekLoading = rows[index].ID
				commands = append(commands, m.peekCmd(rows[index].ID))
			}
		}
		return m, tea.Batch(commands...)
	case motionMsg:
		m.focusSize, m.focusVelocity = m.spring.Update(m.focusSize, m.focusVelocity, 0.68)
		m.slide, m.slideVelocity = m.spring.Update(m.slide, m.slideVelocity, 0)
		if abs(m.focusSize-0.68) < 0.01 && abs(m.slide) < 0.1 {
			m.focusSize, m.slide, m.animating = 0.68, 0, false
			return m, nil
		}
		return m, motionTick()
	case refreshedMsg:
		m.refreshing = false
		if msg.err != nil {
			m.notice = msg.err.Error()
		} else {
			m.data, m.feed = msg.data, msg.feed
			for _, specs := range pages {
				for _, spec := range specs {
					if index, ok := m.selected[spec.id]; ok && index >= len(m.items(spec.id)) {
						delete(m.selected, spec.id)
					}
				}
			}
		}
	case peekMsg:
		m.peekLoading = ""
		if msg.err != nil {
			m.peekText[msg.id] = msg.err.Error()
		} else {
			m.peekText[msg.id] = msg.text
		}
	case noteMsg:
		if msg.err != nil {
			m.notice = msg.err.Error()
		} else {
			m.notice = "Sent to firstmate"
		}
	case focusMsg:
		m.notice = msg.text
		if msg.err != nil && m.notice == "" {
			m.notice = msg.err.Error()
		}
	case spinner.TickMsg:
		var command tea.Cmd
		m.spinner, command = m.spinner.Update(msg)
		return m, command
	case tea.MouseClickMsg:
		for _, rect := range m.lastRects {
			if msg.X >= rect.x && msg.X < rect.x+rect.width && msg.Y >= rect.y && msg.Y < rect.y+rect.height {
				m.focus = rect.id
				m.beginMotion()
				if msg.Y > rect.y+1 {
					m.selected[rect.id] = min(max(0, msg.Y-rect.y-2), max(0, len(m.items(rect.id))-1))
				}
				return m, motionTick()
			}
		}
	case tea.KeyPressMsg:
		key := msg.String()
		if m.help {
			if key == "?" || key == "esc" {
				m.help = false
			}
			if key == "q" {
				return m, tea.Quit
			}
			return m, nil
		}
		if m.filterActive {
			switch key {
			case "esc":
				m.filterActive = false
				m.filterInput.Blur()
				return m, nil
			case "enter":
				m.filters[m.focus] = m.filterInput.Value()
				delete(m.selected, m.focus)
				m.filterActive = false
				m.filterInput.Blur()
				return m, nil
			}
			var command tea.Cmd
			m.filterInput, command = m.filterInput.Update(msg)
			return m, command
		}
		if m.inputActive {
			switch key {
			case "esc":
				m.inputActive = false
				m.commandMode = false
				m.input.Blur()
				return m, nil
			case "enter":
				text := m.input.Value()
				if m.commandMode && strings.TrimSpace(text) == ":q" {
					return m, tea.Quit
				}
				if m.commandMode {
					text = strings.TrimPrefix(text, ":")
				}
				selected := m.focusedItem()
				m.input.Reset()
				m.input.Blur()
				m.inputActive = false
				m.commandMode = false
				return m, m.noteCmd(text, selected)
			}
			var command tea.Cmd
			m.input, command = m.input.Update(msg)
			return m, command
		}
		if m.pendingG {
			m.pendingG = false
			if key == "g" {
				if len(m.items(m.focus)) > 0 {
					m.selected[m.focus] = 0
				}
				return m, nil
			}
		}
		if m.pendingZ {
			m.pendingZ = false
			if key == "a" {
				m.collapsed[m.focus] = !m.collapsed[m.focus]
				return m, nil
			}
		}
		switch key {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "1", "2", "3", "4":
			m.setPage(int(key[0] - '1'))
			return m, motionTick()
		case "tab":
			m.changeFocus(1)
			return m, motionTick()
		case "shift+tab":
			m.changeFocus(-1)
			return m, motionTick()
		case "right", "l":
			m.moveFocusSpatial(1, 0)
			return m, motionTick()
		case "left", "h":
			m.moveFocusSpatial(-1, 0)
			return m, motionTick()
		case "down", "j":
			m.moveSelection(1)
			return m, motionTick()
		case "up", "k":
			m.moveSelection(-1)
			return m, motionTick()
		case "ctrl+d":
			for range 5 {
				m.moveSelection(1)
			}
			return m, nil
		case "ctrl+u":
			for range 5 {
				m.moveSelection(-1)
			}
			return m, nil
		case "ctrl+f":
			if m.page == 3 {
				m.scrollOffset[m.focus] += max(1, m.height/3)
			}
			return m, nil
		case "ctrl+b":
			if m.page == 3 {
				m.scrollOffset[m.focus] = max(0, m.scrollOffset[m.focus]-max(1, m.height/3))
			}
			return m, nil
		case "G":
			if n := len(m.items(m.focus)); n > 0 {
				m.selected[m.focus] = n - 1
			}
			return m, nil
		case "g":
			m.pendingG = true
			return m, nil
		case "z":
			m.pendingZ = true
			return m, nil
		case "space":
			m.collapsed[m.focus] = !m.collapsed[m.focus]
			return m, nil
		case "enter", "o":
			return m, m.expandSelected()
		case "O":
			if m.focus != "workers" {
				m.notice = "Select a worker in WORKERS first"
				return m, nil
			}
			row := m.focusedItem()
			if row == nil {
				m.notice = "Select a worker with j/k first"
				return m, nil
			}
			return m, m.focusCmd(row.ID)
		case "/":
			m.filterActive = true
			m.filterInput.SetValue(m.filters[m.focus])
			return m, m.filterInput.Focus()
		case "i":
			m.inputActive = true
			m.commandMode = false
			m.input.Reset()
			return m, m.input.Focus()
		case ":":
			m.inputActive = true
			m.commandMode = true
			m.input.SetValue(":")
			return m, m.input.Focus()
		case "?":
			m.help = true
			return m, nil
		case "esc":
			delete(m.selected, m.focus)
		default:
			if strings.HasPrefix(key, "alt+") && len(key) == 5 && key[4] >= '1' && key[4] <= '9' {
				index := int(key[4] - '1')
				if index < len(m.items(m.focus)) {
					m.selected[m.focus] = index
				}
				return m, nil
			}
		}
	}
	return m, nil
}

func abs(value float64) float64 {
	if value < 0 {
		return -value
	}
	return value
}
