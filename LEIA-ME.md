# Robô de Leis Estaduais

Todo dia, o robô junta as leis, os decretos e as aprovações **estaduais** que afetam o dia a dia e manda um e-mail com tudo. Ele separa o que é federal e o que é municipal.

**Fontes**
- **Oficiais** (aparecem primeiro, com o selo "FONTE OFICIAL"): ALERJ, Agência SP (Governo de SP), Agência Minas (Governo de MG) e ALMG.
- **Imprensa**: buscas no Google Notícias que cobrem todos os estados.

Não tem nada para instalar. O robô roda no PowerShell, que já vem no Windows.

---

## 1. Configurar o e-mail (obrigatório)

### Gmail
1. Ative a **verificação em duas etapas** na sua Conta Google.
2. Acesse https://myaccount.google.com/apppasswords e crie uma **senha de app** (ex.: "Robo Leis"). O Google mostra 16 letras. Copie.
3. Em `config.json`, no bloco `"email"`, troque `SEU_EMAIL@gmail.com` pelo seu e-mail nos três campos.
4. Copie `segredos.exemplo.json` para um arquivo novo chamado `segredos.json` e cole a senha de app em `"senha_email"`.

### Outlook / Microsoft 365
Use `"servidor_smtp": "smtp.office365.com"` e `"porta": 587`. Em contas corporativas, o envio por SMTP pode estar bloqueado pelo TI. Se estiver, use um Gmail pessoal.

> O `segredos.json` fica só no seu computador. Não compartilhe esse arquivo.

## 2. Testar

Abra o PowerShell nesta pasta e rode:

```
powershell -ExecutionPolicy Bypass -File .\robo.ps1 -Simular
```

O modo simulação gera `previa.html` (abra no navegador) e não envia nada. Para enviar de verdade, rode o mesmo comando sem `-Simular`.

## 3. Agendar para todo dia

```
powershell -ExecutionPolicy Bypass -File .\agendar.ps1
```

O robô passa a rodar todo dia no horário definido em `"agendamento_hora"` no `config.json`. Se o PC estiver desligado nesse horário, ele roda assim que o PC ligar. Para remover, abra o **Agendador de Tarefas** do Windows e apague "Robo Leis Estaduais".

## 4. Resumo com IA (opcional)

Sem IA, o e-mail traz a lista filtrada com os links. Com IA, cada item vem explicado em linguagem simples ("O que muda" / "Como te afeta"), e o que não for estadual é descartado com mais precisão.

Em `config.json`, troque `"provedor": "nenhum"` por um destes e coloque a chave correspondente no `segredos.json`:

| Provedor | Custo | Onde pegar a chave |
|---|---|---|
| `gemini` | costuma ter faixa gratuita | https://aistudio.google.com/apikey |
| `openai` | pago por uso (centavos/mês aqui) | https://platform.openai.com/api-keys |
| `anthropic` | pago por uso (centavos/mês aqui) | https://console.anthropic.com |
| `ollama` | grátis, roda no seu PC | https://ollama.com (instale e rode `ollama pull llama3.1`) |

Os nomes de modelo (`modelo_gemini` etc.) podem ser trocados no `config.json` quando as empresas lançarem versões novas. Se a IA falhar, o robô envia a lista sem resumo e registra o erro em `robo.log`.

## 5. Ajustes

Tudo fica no `config.json`:
- `buscas`: o que é procurado no Google Notícias.
- `fontes_oficiais`: feeds RSS de governos e assembleias. Para outro estado, adicione `{ "nome": ..., "estado": ..., "tipo": "rss", "url": ... }`.
- `palavras_obrigatorias` / `palavras_proibidas`: o filtro sem IA.
- `janela_horas`: até quantas horas atrás olhar (36 h cobre um dia com folga).
- `mais_discutidos_minimo` / `mais_discutidos_max`: quantos veículos diferentes precisam falar de um assunto para ele entrar em "Mais discutidos" (padrão: 3), e quantos assuntos mostrar nessa seção (padrão: 5). Essa seção só existe com a IA ligada.

O robô guarda em `vistos.json` o que já mandou, para não repetir notícia. O histórico de execuções fica em `robo.log`.

**Limitações:** o Governo do RJ (rj.gov.br) e a ALESP não publicam feed aberto, então chegam só pela imprensa. Os resumos da IA usam apenas a manchete e o trecho inicial da notícia. Confira a fonte antes de tomar qualquer decisão.
