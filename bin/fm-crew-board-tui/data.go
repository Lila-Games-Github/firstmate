package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type worker struct {
	ID         string `json:"id"`
	Project    string `json:"project"`
	Title      string `json:"title"`
	Phase      string `json:"phase"`
	PhaseSince int64  `json:"phase_since"`
	Note       string `json:"note"`
	PRURL      string `json:"pr_url"`
	Endpoint   string `json:"endpoint"`
	Gone       bool   `json:"gone"`
}

type item struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Detail string `json:"detail"`
	Status string `json:"status"`
	Link   string `json:"link"`
	Alert  bool   `json:"alert"`
}

type backlog struct {
	Queued   *int   `json:"queued"`
	InFlight *int   `json:"in_flight"`
	Next     []item `json:"next"`
	Source   string `json:"source"`
}

type panels struct {
	Alerts    []item  `json:"alerts"`
	Questions []item  `json:"questions"`
	Ready     []item  `json:"ready"`
	Phones    []item  `json:"phones"`
	TestQueue []item  `json:"test_queue"`
	Landings  []item  `json:"landings"`
	Builds    []item  `json:"builds"`
	Routines  []item  `json:"routines"`
	Bugs      []item  `json:"bugs"`
	Backlog   backlog `json:"backlog"`
	Allowance []item  `json:"allowance"`
	CachedAt  string  `json:"cached_at"`
}

type board struct {
	Schema string   `json:"schema"`
	Home   string   `json:"home"`
	Rows   []worker `json:"rows"`
	Panels panels   `json:"panels"`
}

type paths struct {
	Home  string
	State string
	Data  string
	Code  string
}

func (p paths) env() []string {
	return append(os.Environ(), "FM_HOME="+p.Home, "FM_STATE_OVERRIDE="+p.State,
		"FM_DATA_OVERRIDE="+p.Data)
}

func (p paths) readBoard() (board, error) {
	var value board
	raw, err := os.ReadFile(filepath.Join(p.State, "crew-board.json"))
	if err != nil {
		return value, err
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return value, err
	}
	if value.Schema != "fm-crew-board.v1" {
		return value, fmt.Errorf("unsupported crew board schema %q", value.Schema)
	}
	return value, nil
}

func (b board) liveWorkers() []worker {
	rows := make([]worker, 0, len(b.Rows))
	for _, row := range b.Rows {
		if !row.Gone {
			rows = append(rows, row)
		}
	}
	return rows
}

func phaseCounts(rows []worker) map[string]int {
	counts := make(map[string]int)
	for _, row := range rows {
		if !row.Gone {
			counts[row.Phase]++
		}
	}
	return counts
}

func elapsed(since int64, now time.Time) string {
	seconds := max(0, int(now.Unix()-since))
	switch {
	case seconds < 60:
		return "<1m"
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86400:
		return fmt.Sprintf("%dh%dm", seconds/3600, seconds%3600/60)
	default:
		return fmt.Sprintf("%dd%dh", seconds/86400, seconds%86400/3600)
	}
}

func (p paths) refresh() (board, []item, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(p.Code, "bin", "fm-crew-board.sh"), "refresh")
	cmd.Env = p.env()
	if output, err := cmd.CombinedOutput(); err != nil {
		return board{}, nil, fmt.Errorf("refresh: %s: %w", strings.TrimSpace(string(output)), err)
	}
	value, err := p.readBoard()
	if err != nil {
		return board{}, nil, err
	}
	feed, err := readFeed(p.State)
	return value, feed, err
}

func (p paths) sendNote(text string, selected *item) error {
	text = strings.TrimSpace(text)
	if text == "" && selected == nil {
		return errors.New("write a note or select an item")
	}
	body := text
	if selected != nil {
		body = "Crew board item: " + selected.ID + " | " + selected.Title
		if selected.Status != "" {
			body += " | " + selected.Status
		}
		if text != "" {
			body += "\nNote: " + text
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(p.Code, "bin", "fm-inbox.sh"), "note", "-")
	cmd.Env = p.env()
	cmd.Stdin = strings.NewReader(body)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("inbox: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

var ansiEscape = regexp.MustCompile(`\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\][^\a]*(?:\a|\x1b\\))`)

func (p paths) peek(id string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(p.Code, "bin", "fm-peek.sh"), id, "32")
	cmd.Env = p.env()
	output, err := cmd.CombinedOutput()
	text := string(ansiEscape.ReplaceAll(output, nil))
	if err != nil {
		return "", fmt.Errorf("peek %s: %s: %w", id, strings.TrimSpace(text), err)
	}
	return strings.TrimSpace(text), nil
}

func readFeed(state string) ([]item, error) {
	matches, err := filepath.Glob(filepath.Join(state, "*.status"))
	if err != nil {
		return nil, err
	}
	type event struct {
		timestamp time.Time
		sequence  int
		value     item
	}
	var events []event
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if len(data) > 8192 {
			data = data[len(data)-8192:]
			if i := bytes.IndexByte(data, '\n'); i >= 0 {
				data = data[i+1:]
			}
		}
		lines := strings.Split(string(data), "\n")
		id := strings.TrimSuffix(filepath.Base(path), ".status")
		for index, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			events = append(events, event{info.ModTime(), index,
				item{ID: id, Title: id + ": " + line, Detail: line, Status: "event"}})
		}
	}
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].timestamp.Equal(events[j].timestamp) {
			return events[i].sequence < events[j].sequence
		}
		return events[i].timestamp.Before(events[j].timestamp)
	})
	if len(events) > 100 {
		events = events[len(events)-100:]
	}
	rows := make([]item, 0, len(events))
	for _, event := range events {
		value := event.value
		value.Status = event.timestamp.Format("15:04:05")
		rows = append(rows, value)
	}
	return rows, nil
}
