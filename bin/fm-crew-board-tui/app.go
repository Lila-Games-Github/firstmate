package main

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

type panelSpec struct{ id, title string }

var pages = [][]panelSpec{
	{{"workers", "WORKERS"}, {"ready", "READY FOR YOU"}, {"feed", "FEED"}},
	{{"bugs", "ROCKETBOARD BUGS"}, {"backlog", "BACKLOG"}},
	{{"full_questions", "CAPTAIN QUESTIONS"}},
	{{"landings", "TODAY'S LANDINGS"}},
}

var railPanels = []panelSpec{{"alerts", "NOTIFICATIONS"}, {"test_queue", "TEST QUEUE"},
	{"builds", "LATEST BUILDS"}, {"routines", "DAILY ROUTINES"}, {"allowance", "AI ALLOWANCE"}}

var pageNames = []string{"NOW", "PLANNING", "QUESTIONS", "TESTING"}
var questionLabelPattern = regexp.MustCompile(`^([A-Za-z0-9_-]+)\.`)

type tickMsg time.Time
type motionMsg struct{}
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
	paths                 paths
	data                  board
	feed                  []item
	width, height         int
	page                  int
	focus                 string
	selected              map[string]int
	expanded              map[string]int
	collapsed             map[string]bool
	filters               map[string]string
	peekText              map[string]string
	scrollOffset          map[string]int
	peekLoading           string
	input                 textinput.Model
	inputActive           bool
	filterInput           textinput.Model
	filterActive          bool
	commandMode           bool
	help                  bool
	pendingG, pendingZ    bool
	spinner               spinner.Model
	notice                string
	lastRefresh           time.Time
	refreshing            bool
	replyTarget           *item
	lastRects             []panelRect
	slide, slideDirection int
	seen                  map[string]string
	railOpen              bool
	railOffset            int
	railHit               map[int]item
	railDetail            *item
	railDetailOffset      int
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
		seen:  loadSeen(p.State),
		input: input, filterInput: filter, spinner: spinner.New(spinner.WithSpinner(spinner.MiniDot)),
	}
}

func (m *app) Init() tea.Cmd {
	return tea.Batch(tick(), func() tea.Msg { return m.spinner.Tick() })
}
func tick() tea.Cmd { return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) }) }
func motionTick() tea.Cmd {
	return tea.Tick(35*time.Millisecond, func(time.Time) tea.Msg { return motionMsg{} })
}

func (m *app) beginTransition(direction int) {
	m.slide = 2
	m.slideDirection = direction
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

// backlogRows shows the full backlog when it carries a task, else the failed
// read's own reason above the next queued tasks.
func backlogRows(full, next []item) []item {
	tasks := withoutSections(full)
	if len(tasks) > 0 && tasks[0].Status != "error" {
		return full
	}
	reason := []item{}
	for _, row := range full {
		if row.Status == "section" {
			continue
		}
		if row.Detail != "" && !strings.Contains(row.Title, row.Detail) {
			row.Title += ": " + row.Detail
		}
		reason = append(reason, row)
	}
	return append(reason, next...)
}

func (m *app) rawItems(id string) []item {
	switch id {
	case "alerts":
		return m.data.Panels.Alerts
	case "full_questions":
		return m.data.Panels.FullQuestions
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
			Status: "section"}}
		return append(rows, backlogRows(m.data.Panels.FullBacklog, back.Next)...)
	case "workers":
		workers := m.data.liveWorkers()
		order := map[string]int{}
		for _, worker := range workers {
			project := worker.Project
			if project == "" {
				project = "unknown project"
			}
			if _, exists := order[project]; !exists {
				order[project] = len(order)
			}
		}
		waiting := func(w worker) bool { return m.data.Panels.MergeWaiting[w.ID] != "" }
		sort.SliceStable(workers, func(i, j int) bool {
			if waiting(workers[i]) != waiting(workers[j]) {
				return waiting(workers[i])
			}
			left, right := workers[i].Project, workers[j].Project
			if left == "" {
				left = "unknown project"
			}
			if right == "" {
				right = "unknown project"
			}
			return order[left] < order[right]
		})
		rows := make([]item, 0, len(workers))
		for _, worker := range workers {
			project := worker.Project
			if project == "" {
				project = "unknown project"
			}
			detail := worker.Note
			if rt, ok := m.data.Panels.WorkerRuntimes[worker.ID]; ok {
				detail = "Runtime: " + rt.full() + "\n" + detail
			}
			status, group, link := worker.Phase, project, worker.PRURL
			if url := m.data.Panels.MergeWaiting[worker.ID]; url != "" {
				status, group, link = mergeWaitingPhase, mergeWaitingGroup, url
				if worker.PRURL == "" {
					worker.PRURL = url
				}
			}
			if worker.PRURL != "" {
				label := "PR: "
				if worker.Kind == "playbot" {
					label = "Chat: "
				}
				detail += "\n" + label + worker.PRURL
			}
			rows = append(rows, item{ID: worker.ID, Group: group, Title: project + " / " + worker.Title,
				Detail: strings.TrimSpace(detail), Status: status, Link: link})
		}
		return rows
	}
	return nil
}

const (
	mergeWaitingPhase = "pr-ready"
	mergeWaitingGroup = "PR ready to merge"
)

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

func (m *app) pointedItem() *item {
	if m.railDetail != nil {
		return m.railDetail
	}
	return m.focusedItem()
}

func (m *app) selectedQuestion() *item {
	if m.railDetail != nil || m.focus != "full_questions" {
		return nil
	}
	row := m.focusedItem()
	if row == nil || row.Status == "section" {
		return nil
	}
	return row
}

func questionLabel(title string) string {
	if match := questionLabelPattern.FindStringSubmatch(title); match != nil {
		return match[1]
	}
	return title
}

func (m *app) alertCount(page int) int {
	count := 0
	if page == 0 {
		count += len(m.newAlerts())
	}
	for _, spec := range pages[page] {
		for _, row := range m.rawItems(spec.id) {
			if row.Alert && (spec.id != "alerts" || m.isNew(row)) {
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
	m.railDetail = nil
	m.focus = pages[page][0].id
	if page == 0 {
		m.focus = "workers"
	}
	m.selectReadable()
	m.beginTransition(1)
}

// selectReadable puts the cursor on the first question when the questions
// panel gains focus, so its full text shows without a key press.
func (m *app) selectReadable() {
	if m.focus != "full_questions" {
		return
	}
	if index, ok := m.selected[m.focus]; ok && index < len(m.items(m.focus)) {
		return
	}
	if first := m.selectableFrom(0, 1); first >= 0 {
		m.selected[m.focus] = first
	}
}

// selectableFrom returns the first non-heading row from index in direction
// step, or -1 when none remains.
func (m *app) selectableFrom(index, step int) int {
	return m.selectableIn(m.focus, index, step)
}

// selectableIn is selectableFrom for any panel.
func (m *app) selectableIn(id string, index, step int) int {
	rows := m.items(id)
	for ; index >= 0 && index < len(rows); index += step {
		if rows[index].Status != "section" {
			return index
		}
	}
	return -1
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
	if list[index].id == m.focus {
		return
	}
	m.focus = list[index].id
	m.selectReadable()
	m.beginTransition(step)
}

func (m *app) focusSubTab(id string) bool {
	if id == "" || id == m.focus {
		return false
	}
	direction := 1
	for _, spec := range pages[m.page] {
		if spec.id == id {
			direction = -1
			break
		}
		if spec.id == m.focus {
			break
		}
	}
	m.focus = id
	m.selectReadable()
	m.beginTransition(direction)
	return true
}

// moveSelection moves the cursor within the focused panel only, skipping
// section headings and stopping at the panel's first and last rows.
func (m *app) moveSelection(step int) {
	rows := m.items(m.focus)
	index, ok := m.selected[m.focus]
	switch {
	case !ok && step < 0:
		index = m.selectableFrom(len(rows)-1, -1)
	case !ok:
		index = m.selectableFrom(0, 1)
	default:
		index = m.selectableFrom(index+step, step)
	}
	if index < 0 {
		return
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
	model, command := m.update(message)
	switch message.(type) {
	case tea.KeyPressMsg, tea.MouseClickMsg:
		m.markViewed()
	}
	return model, command
}

func (m *app) update(message tea.Msg) (tea.Model, tea.Cmd) {
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
	case refreshedMsg:
		m.refreshing = false
		if msg.err != nil {
			m.notice = msg.err.Error()
		} else {
			m.data, m.feed = msg.data, msg.feed
			m.pruneSeen()
			for _, specs := range pages {
				for _, spec := range specs {
					index, ok := m.selected[spec.id]
					if !ok {
						continue
					}
					near := m.selectableIn(spec.id, index, 1)
					if near < 0 {
						near = m.selectableIn(spec.id, min(index, len(m.items(spec.id))-1), -1)
					}
					if near < 0 {
						delete(m.selected, spec.id)
					} else {
						m.selected[spec.id] = near
					}
				}
			}
			m.selectReadable()
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
	case motionMsg:
		if m.slide > 0 {
			m.slide--
			if m.slide > 0 {
				return m, motionTick()
			}
		}
		return m, nil
	case tea.MouseClickMsg:
		if msg.Y == 2 {
			if m.help || m.filterActive || m.inputActive {
				return m, nil
			}
			if page := m.pageTabAt(msg.X - 1); page >= 0 && page != m.page {
				m.setPage(page)
				return m, motionTick()
			}
			return m, nil
		}
		if m.help || m.filterActive || m.railDetail != nil {
			return m, nil
		}
		if row, ok := m.railHit[msg.Y]; ok && !m.inputActive &&
			(m.railOpen || m.width >= 100 && msg.X >= m.width-max(34, m.width/3)) {
			m.railDetail = &row
			m.railDetailOffset = 0
			if row.Alert {
				nid, sig := alertKey(row)
				m.seen[nid] = sig
				m.saveSeen()
			}
			return m, nil
		}
		for _, rect := range m.lastRects {
			if msg.X >= rect.x && msg.X < rect.x+rect.width && msg.Y >= rect.y && msg.Y < rect.y+rect.height {
				if rect.id != m.focus {
					if m.focusSubTab(rect.id) {
						return m, motionTick()
					}
					return m, nil
				}
				innerWidth := max(1, rect.width-4)
				innerHeight := max(1, rect.height-5)
				if msg.Y == rect.y+1 {
					if m.focusSubTab(m.subTabAt(msg.X-rect.x-1, innerWidth)) {
						return m, motionTick()
					}
					return m, nil
				}
				if msg.Y >= rect.y+3 && msg.Y < rect.y+3+innerHeight && !m.collapsed[rect.id] {
					_, owners := m.panelLines(panelSpec{id: rect.id}, innerWidth)
					line := msg.Y - rect.y - 3 + m.panelOffset(panelSpec{id: rect.id}, innerWidth, rect.height, owners)
					if line >= 0 && line < len(owners) && owners[line] >= 0 {
						m.selected[rect.id] = owners[line]
					}
				}
				return m, nil
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
				m.replyTarget = nil
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
				selected := m.pointedItem()
				if question := m.replyTarget; question != nil {
					selected = question
					if strings.TrimSpace(text) != "" {
						text = fmt.Sprintf("Reply [%s]: %s\nAnswer: %s", questionLabel(question.Title), question.Title, text)
					}
				}
				m.replyTarget = nil
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
				if first := m.selectableFrom(0, 1); first >= 0 {
					m.selected[m.focus] = first
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
		case "s":
			m.railDetail = nil
			m.railOpen = !m.railOpen
			return m, nil
		case "ctrl+n":
			if m.railDetail != nil {
				m.railDetailOffset += 3
			} else {
				m.railOffset += 3
			}
			return m, nil
		case "ctrl+p":
			if m.railDetail != nil {
				m.railDetailOffset = max(0, m.railDetailOffset-3)
			} else {
				m.railOffset = max(0, m.railOffset-3)
			}
			return m, nil
		case "q", "ctrl+c":
			return m, tea.Quit
		case "1", "2", "3", "4":
			m.setPage(int(key[0] - '1'))
			if m.slide > 0 {
				return m, motionTick()
			}
			return m, nil
		case "tab":
			m.changeFocus(1)
			return m, motionTick()
		case "shift+tab":
			m.changeFocus(-1)
			return m, motionTick()
		case "right", "l":
			m.changeFocus(1)
			return m, motionTick()
		case "left", "h":
			m.changeFocus(-1)
			return m, motionTick()
		case "down", "j":
			m.moveSelection(1)
			return m, nil
		case "up", "k":
			m.moveSelection(-1)
			return m, nil
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
			if m.focus == "full_questions" || m.focus == "backlog" {
				m.scrollOffset[m.focus] += max(1, m.height/3)
			}
			return m, nil
		case "ctrl+b":
			if m.focus == "full_questions" || m.focus == "backlog" {
				m.scrollOffset[m.focus] = max(0, m.scrollOffset[m.focus]-max(1, m.height/3))
			}
			return m, nil
		case "G":
			if last := m.selectableFrom(len(m.items(m.focus))-1, -1); last >= 0 {
				m.selected[m.focus] = last
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
			m.replyTarget = m.selectedQuestion()
			m.inputActive = true
			m.commandMode = false
			m.input.Reset()
			return m, m.input.Focus()
		case "r":
			target := m.selectedQuestion()
			if target == nil {
				m.notice = "Select a question to reply"
				return m, nil
			}
			m.replyTarget = target
			m.inputActive = true
			m.commandMode = false
			m.input.Reset()
			return m, m.input.Focus()
		case ":":
			m.replyTarget = m.selectedQuestion()
			m.inputActive = true
			m.commandMode = true
			m.input.SetValue(":")
			return m, m.input.Focus()
		case "?":
			m.help = true
			return m, nil
		case "esc":
			if m.railDetail != nil {
				m.railDetail = nil
				return m, nil
			}
			delete(m.selected, m.focus)
		default:
			if strings.HasPrefix(key, "alt+") && len(key) == 5 && key[4] >= '1' && key[4] <= '9' {
				index := int(key[4] - '1')
				if index < len(m.items(m.focus)) && m.items(m.focus)[index].Status != "section" {
					m.selected[m.focus] = index
				}
				return m, nil
			}
		}
	}
	return m, nil
}
