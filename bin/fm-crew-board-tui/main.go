package main

import (
	tea "charm.land/bubbletea/v2"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func configuration() (paths, error) {
	p := paths{Home: os.Getenv("FM_HOME"), State: os.Getenv("FM_STATE_OVERRIDE"), Data: os.Getenv("FM_DATA_OVERRIDE"), Code: os.Getenv("FM_CODE_ROOT")}
	if p.Home == "" {
		return p, errors.New("FM_HOME is required")
	}
	if p.State == "" {
		p.State = filepath.Join(p.Home, "state")
	}
	if p.Data == "" {
		p.Data = filepath.Join(p.Home, "data")
	}
	return p, nil
}

func processFile(state string) string { return filepath.Join(state, ".crew-board-tui.pid") }

func activeProcess(state string) int {
	content, err := os.ReadFile(processFile(state))
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil || pid < 1 {
		return 0
	}
	output, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "command=").Output()
	if err != nil {
		return 0
	}
	command := strings.TrimSpace(string(output))
	if strings.Contains(command, ".crew-board-tui-bin run") {
		return pid
	}
	return 0
}

func stop(state string) error {
	pid := activeProcess(state)
	if pid == 0 {
		fmt.Println("tui: not running")
		return nil
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	if err := process.Signal(syscall.SIGTERM); err != nil {
		return err
	}
	fmt.Printf("tui: stopped %d\n", pid)
	return nil
}

func run(p paths) error {
	if p.Code == "" {
		return errors.New("FM_CODE_ROOT is required")
	}
	if pid := activeProcess(p.State); pid != 0 {
		return fmt.Errorf("crew board already open in process %d", pid)
	}
	data, err := p.readBoard()
	if err != nil {
		return err
	}
	feed, err := readFeed(p.State)
	if err != nil {
		return err
	}
	pidFile := processFile(p.State)
	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())+"\n"), 0600); err != nil {
		return err
	}
	defer func() {
		if content, err := os.ReadFile(pidFile); err == nil && strings.TrimSpace(string(content)) == strconv.Itoa(os.Getpid()) {
			_ = os.Remove(pidFile)
		}
	}()
	program := tea.NewProgram(newApp(p, data, feed))
	term := make(chan os.Signal, 1)
	signal.Notify(term, syscall.SIGTERM)
	defer signal.Stop(term)
	go func() { <-term; program.Quit() }()
	_, err = program.Run()
	return err
}

func main() {
	if len(os.Args) != 2 || (os.Args[1] != "run" && os.Args[1] != "stop") {
		fmt.Fprintln(os.Stderr, "usage: fm-crew-board-tui run|stop")
		os.Exit(2)
	}
	p, err := configuration()
	if err == nil {
		if os.Args[1] == "stop" {
			err = stop(p.State)
		} else {
			err = run(p)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "crew board:", err)
		os.Exit(1)
	}
}
