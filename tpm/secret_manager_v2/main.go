package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea" 
	"github.com/charmbracelet/lipgloss" 
	"github.com/charmbracelet/bubbles/textinput" 
)

// Estilos de Layout
var (
	titleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("212")).
			Border(lipgloss.DoubleBorder()).
			Padding(0, 1).
			Align(lipgloss.Center).
			Width(50)

	successStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("46")).
			Border(lipgloss.RoundedBorder()).
			Padding(1, 2)

	errorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196")).
			Border(lipgloss.RoundedBorder()).
			Padding(1, 2)

	focusedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("205"))
	blurStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
)

const (
	tpmIndex = "0x1500000"
	tpmDevice = "device:/dev/tpmrm0"
)

// Estados da TUI
type sessionState int

const (
	stateMenu sessionState = iota
	stateInsert
	stateList
	stateSuccess
	stateError
)

type model struct {
	state       sessionState
	menuIndex   int
	inputs      []textinput.Model
	focusedIdx  int
	secrets     map[string]string
	keysList    []string
	selectedKey int
	statusMsg   string
	errMessage  string
}

func initialModel() model {
	m := model{
		state:     stateMenu,
		menuIndex: 0,
		secrets:   make(map[string]string),
	}

	// Configura os campos de input para a inserção de novos segredos
	keyInput := textinput.New()
	keyInput.Placeholder = "Nome do segredo (Ex: github)"
	keyInput.Focus()
	keyInput.PromptStyle = focusedStyle
	keyInput.TextStyle = focusedStyle

	valInput := textinput.New()
	valInput.Placeholder = "Valor do segredo"
	valInput.PromptStyle = blurStyle

	m.inputs = []textinput.Model{keyInput, valInput}
	return m
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
}

// Funções Auxiliares para conversar com o fTPM via comandos de baixo nível
func readTPM() (map[string]string, error) {
	secrets := make(map[string]string)
	cmd := exec.Command("sudo", "tpm2_nvread", "-T", tpmDevice, "-s", "2048", tpmIndex)
	output, err := cmd.Output()
	if err != nil {
		// Se o índice não existir ou falhar, retorna vazio mas funcional
		return secrets, nil
	}

	// Limpa bytes nulos e quebra as linhas de texto estruturado
	cleanStr := strings.ReplaceAll(string(output), "\x00", "")
	lines := strings.Split(cleanStr, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, "=") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		secrets[parts[0]] = parts[1]
	}
	return secrets, nil
}

func writeTPM(secrets map[string]string) error {
	var sb strings.Builder
	for k, v := range secrets {
		sb.WriteString(fmt.Sprintf("%s=%s\n", k, v))
	}
	payload := sb.String()

	if len(payload) > 2048 {
		return fmt.Errorf("limite de 2048 bytes excedido")
	}

	cmd := exec.Command("sudo", "tpm2_nvwrite", "-T", tpmDevice, "-i", "-", tpmIndex)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}

	go func() {
		defer stdin.Close()
		io.WriteString(stdin, payload)
	}()

	return cmd.Run()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			if m.state == stateMenu || m.state == stateSuccess || m.state == stateError {
				return m, tea.Quit
			}
			m.state = stateMenu
			return m, nil
		}

		// Lógica do Menu Principal
		if m.state == stateMenu {
			switch msg.String() {
			case "up", "k":
				if m.menuIndex > 0 {
					m.menuIndex--
				}
			case "down", "j":
				if m.menuIndex < 1 {
					m.menuIndex++
				}
			case "enter":
				if m.menuIndex == 0 {
					m.state = stateInsert
					m.inputs[0].Focus()
					m.focusedIdx = 0
				} else {
					var err error
					m.secrets, err = readTPM()
					if err != nil {
						m.state = stateError
						m.errMessage = err.Error()
						return m, nil
					}
					m.keysList = []string{}
					for k := range m.secrets {
						m.keysList = append(m.keysList, k)
					}
					if len(m.keysList) == 0 {
						m.state = stateError
						m.errMessage = "Nenhum segredo encontrado no fTPM."
						return m, nil
					}
					m.state = stateList
					m.selectedKey = 0
				}
			}
			return m, nil
		}

		// Lógica da Tela de Inserção de Dados
		if m.state == stateInsert {
			switch msg.String() {
			case "tab", "shift+tab", "enter", "up", "down":
				s := msg.String()

				if s == "enter" && m.focusedIdx == 1 {
					key := strings.TrimSpace(m.inputs[0].Value())
					val := m.inputs[1].Value()
					if key == "" || val == "" {
						return m, nil
					}

					// Processo de Leitura -> Mesclagem -> Escrita
					current, err := readTPM()
					if err != nil {
						m.state = stateError
						m.errMessage = err.Error()
						return m, nil
					}
					current[key] = val
					err = writeTPM(current)
					if err != nil {
						m.state = stateError
						m.errMessage = err.Error()
						return m, nil
					}

					m.state = stateSuccess
					m.statusMsg = fmt.Sprintf("Segredo '%s' gravado com sucesso no hardware!", key)
					m.inputs[0].SetValue("")
					m.inputs[1].SetValue("")
					return m, nil
				}

				// Alterna o foco entre campos
				m.inputs[m.focusedIdx].Blur()
				if s == "up" || s == "shift+tab" {
					m.focusedIdx--
				} else {
					m.focusedIdx++
				}

				if m.focusedIdx < 0 {
					m.focusedIdx = 0
				} else if m.focusedIdx > 1 {
					m.focusedIdx = 1
				}

				m.inputs[m.focusedIdx].Focus()
				return m, nil
			}

			// Passa os inputs do teclado para o campo focado
			var cmd tea.Cmd
			m.inputs[m.focusedIdx], cmd = m.inputs[m.focusedIdx].Update(msg)
			return m, cmd
		}

		// Lógica da Lista de Seleção Bubble Tea
		if m.state == stateList {
			switch msg.String() {
			case "up", "k":
				if m.selectedKey > 0 {
					m.selectedKey--
				}
			case "down", "j":
				if m.selectedKey < len(m.keysList)-1 {
					m.selectedKey++
				}
			case "enter":
				key := m.keysList[m.selectedKey]
				val := m.secrets[key]
				m.state = stateSuccess
				m.statusMsg = fmt.Sprintf("Chave: %s\nValor: %s", key, val)
			}
			return m, nil
		}

		// Retorno para telas de status final
		if m.state == stateSuccess || m.state == stateError {
			if msg.String() == "enter" {
				m.state = stateMenu
			}
		}
	}
	return m, nil
}

func (m model) View() string {
	var s strings.Builder
	s.WriteString(titleStyle.Render("Banco de Dados fTPM via Bubble Tea") + "\n\n")

	switch m.state {
	case stateMenu:
		s.WriteString("Selecione uma ação:\n\n")
		options := []string{"[1] Adicionar/Atualizar Segredo", "[2] Listar e Revelar Segredos"}
		for i, opt := range options {
			if m.menuIndex == i {
				s.WriteString(focusedStyle.Render(fmt.Sprintf(" > %s", opt)) + "\n")
			} else {
				s.WriteString(blurStyle.Render(fmt.Sprintf("   %s", opt)) + "\n")
			}
		}
		s.WriteString("\n(Pressione up/down para navegar, Enter para escolher, 'q' para sair)\n")

	case stateInsert:
		s.WriteString("Inserir novo segredo no Hardware:\n\n")
		for i, input := range m.inputs {
			if i == m.focusedIdx {
				s.WriteString(focusedStyle.Render(input.View()) + "\n")
			} else {
				s.WriteString(input.View() + "\n")
			}
		}
		s.WriteString("\n(Tab para alternar campos, Enter no último campo para salvar)\n")

	case stateList:
		s.WriteString("Selecione a chave armazenada no fTPM:\n\n")
		for i, key := range m.keysList {
			if m.selectedKey == i {
				s.WriteString(focusedStyle.Render(fmt.Sprintf(" > %s", key)) + "\n")
			} else {
				s.WriteString(blurStyle.Render(fmt.Sprintf("   %s", key)) + "\n")
			}
		}
		s.WriteString("\n(Aperte Enter para descriptografar e revelar o valor)\n")

	case stateSuccess:
		s.WriteString(successStyle.Render(m.statusMsg) + "\n\n")
		s.WriteString("(Pressione Enter para voltar ao menu principal)")

	case stateError:
		s.WriteString(errorStyle.Render("Erro Detectado:\n"+m.errMessage) + "\n\n")
		s.WriteString("(Pressione Enter para voltar)")
	}

	return s.String()
}

func main() {
	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Ocorreu um erro no Bubble Tea: %v", err)
		os.Exit(1)
	}
}

