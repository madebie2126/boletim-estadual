# Robô de Leis Estaduais
# Busca notícias de leis/decretos/aprovações estaduais no Google Notícias, filtra o que é
# federal ou municipal, (opcionalmente) resume com IA e envia um e-mail diário.
#
# Uso:
#   .\robo.ps1            -> busca e envia o e-mail
#   .\robo.ps1 -Simular   -> busca e grava previa.html, sem enviar nem marcar como lido

param([switch]$Simular)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = $PSScriptRoot

function Ler-Json($caminho) { Get-Content $caminho -Raw -Encoding UTF8 | ConvertFrom-Json }

function Log($msg) {
  $linha = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
  Write-Host $linha
  Add-Content -Path "$base\robo.log" -Value $linha -Encoding UTF8
}

# Requisição HTTP sempre decodificada como UTF-8 (o PowerShell 5.1 às vezes erra os acentos)
function Pedir($url, $metodo = 'GET', $corpo = $null, $cabecalhos = @{}) {
  $p = @{ Uri = $url; Method = $metodo; UseBasicParsing = $true; Headers = $cabecalhos; TimeoutSec = 300 }
  if ($corpo) {
    $p.Body = [Text.Encoding]::UTF8.GetBytes($corpo)
    $p.ContentType = 'application/json; charset=utf-8'
  }
  $r = Invoke-WebRequest @p
  [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

function Contem($texto, $lista) {
  foreach ($t in $lista) {
    if ($texto -match ('(?<![\p{L}\p{N}])' + [regex]::Escape($t) + '(?![\p{L}\p{N}])')) { return $true }
  }
  return $false
}

function Html($s) { [Net.WebUtility]::HtmlEncode([string]$s) }

$cfg = Ler-Json "$base\config.json"
# No PC as senhas vêm do segredos.json; na nuvem (GitHub Actions) vêm de variáveis de ambiente
$seg = if (Test-Path "$base\segredos.json") { Ler-Json "$base\segredos.json" } else {
  [pscustomobject]@{
    email_conta = $env:EMAIL_CONTA; email_destinatario = $env:EMAIL_DESTINATARIO; senha_email = $env:SENHA_EMAIL
    chave_gemini = $env:CHAVE_GEMINI; chave_openai = $env:CHAVE_OPENAI; chave_anthropic = $env:CHAVE_ANTHROPIC
  }
}
# O e-mail também fica fora do config.json, porque o config vai para um repositório público
$emailConta = if ($seg.email_conta) { $seg.email_conta } else { $cfg.email.usuario }
$emailPara = if ($seg.email_destinatario) { $seg.email_destinatario } elseif ($cfg.email.destinatario) { $cfg.email.destinatario } else { $emailConta }

# ---------- 1. Coleta ----------
$vistosArq = "$base\vistos.json"
$vistos = @{}
if (Test-Path $vistosArq) {
  (Ler-Json $vistosArq).PSObject.Properties | ForEach-Object { $vistos[$_.Name] = $_.Value }
}

$limite = (Get-Date).AddHours(-$cfg.janela_horas)
$dias = [math]::Max(1, [math]::Ceiling($cfg.janela_horas / 24))
$invariante = [Globalization.CultureInfo]::InvariantCulture
$achados = @{}

# Texto de um nó XML (alguns feeds trazem o título como elemento CDATA)
function Txt($no) { if ($no -is [string]) { $no } elseif ($no) { $no.InnerText } else { '' } }

function Limpar($html) {
  $t = [Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>', ' '))
  $t = ($t -replace '\s+', ' ').Trim()
  if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
  $t
}

function Adicionar($titulo, $fonte, $link, $data, $resumo = '', $oficial = $false, $estado = '') {
  $titulo = (Limpar $titulo)
  if (-not $titulo -or $data -lt $limite) { return }
  $chave = ($titulo.ToLower() -replace '[^\p{L}\p{N}]', '')
  if ($vistos.ContainsKey($chave) -or $achados.ContainsKey($chave)) { return }
  $texto = "$titulo $resumo"
  if (-not (Contem $texto $cfg.palavras_obrigatorias)) { return }
  if (Contem $texto $cfg.palavras_proibidas) { return }
  $script:achados[$chave] = [pscustomobject]@{
    chave = $chave; titulo = $titulo; fonte = $fonte; link = $link; data = $data
    resumo = $resumo; oficial = $oficial; estado = $estado
  }
}

# 1a. Fontes oficiais dos estados
foreach ($f in $cfg.fontes_oficiais) {
  try {
    $conteudo = Pedir $f.url
    if ($f.tipo -eq 'rss') {
      foreach ($it in ([xml]$conteudo).rss.channel.item) {
        $data = [DateTimeOffset]::Parse((Txt $it.pubDate), $invariante).LocalDateTime
        Adicionar (Txt $it.title) $f.nome (Txt $it.link) $data (Limpar (Txt $it.description)) $true $f.estado
      }
    }
    elseif ($f.tipo -eq 'alerj') {
      # A ALERJ não tem RSS: lê os destaques da página inicial (data | título | resumo)
      $ids = [regex]::Matches($conteudo, '/Visualizar/Noticia/(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
      foreach ($id in $ids) {
        $i = $conteudo.IndexOf("/Visualizar/Noticia/$id")
        $fim = $conteudo.IndexOf('</li>', $i)
        if ($fim -lt 0) { continue }
        $bloco = $conteudo.Substring($i, $fim - $i) -replace '<svg[\s\S]*?</svg>', ''
        $partes = @(($bloco -replace '^[^>]*>', '' -replace '<[^>]+>', '|' -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $m = [regex]::Match(($partes -join '|'), '(\d{2}\.\d{2}\.\d{4} - \d{2}:\d{2})\|([^|]+)\|?([^|]*)')
        if (-not $m.Success) { continue }
        $data = [datetime]::ParseExact($m.Groups[1].Value, 'dd.MM.yyyy - HH:mm', $invariante)
        Adicionar $m.Groups[2].Value $f.nome "https://www.alerj.rj.gov.br/Visualizar/Noticia/$id" $data (Limpar $m.Groups[3].Value) $true $f.estado
      }
    }
  } catch { Log "Falha na fonte oficial [$($f.nome)]: $($_.Exception.Message)" }
}

# 1b. Imprensa, via buscas no Google Notícias
foreach ($busca in $cfg.buscas) {
  $q = [uri]::EscapeDataString("$busca when:${dias}d")
  $url = "https://news.google.com/rss/search?q=$q&hl=pt-BR&gl=BR&ceid=BR:pt-419"
  try { $xml = [xml](Pedir $url) } catch { Log "Falha na busca [$busca]: $($_.Exception.Message)"; continue }

  foreach ($it in $xml.rss.channel.item) {
    $data = [DateTimeOffset]::Parse($it.pubDate, $invariante).LocalDateTime
    $fonte = Txt $it.source
    $titulo = [string]$it.title
    if ($fonte -and $titulo.EndsWith(" - $fonte")) { $titulo = $titulo.Substring(0, $titulo.Length - $fonte.Length - 3) }
    Adicionar $titulo $fonte ([string]$it.link) $data
  }
}

$itens = @($achados.Values |
  Sort-Object @{ Expression = 'oficial'; Descending = $true }, @{ Expression = 'data'; Descending = $true } |
  Select-Object -First $cfg.max_itens)
Log "Coleta: $($itens.Count) notícia(s) nova(s) após o filtro."

# ---------- 2. Resumo com IA (opcional) ----------
function Chamar-IA($prompt) {
  $prov = $cfg.ia.provedor
  switch ($prov) {
    'gemini' {
      $corpo = @{ contents = @(@{ parts = @(@{ text = $prompt }) }); generationConfig = @{ responseMimeType = 'application/json'; temperature = 0 } } | ConvertTo-Json -Depth 10
      $r = Pedir "https://generativelanguage.googleapis.com/v1beta/models/$($cfg.ia.modelo_gemini):generateContent" 'POST' $corpo @{ 'x-goog-api-key' = $seg.chave_gemini }
      return ($r | ConvertFrom-Json).candidates[0].content.parts[0].text
    }
    'openai' {
      $corpo = @{ model = $cfg.ia.modelo_openai; messages = @(@{ role = 'user'; content = $prompt }); response_format = @{ type = 'json_object' } } | ConvertTo-Json -Depth 10
      $r = Pedir 'https://api.openai.com/v1/chat/completions' 'POST' $corpo @{ Authorization = "Bearer $($seg.chave_openai)" }
      return ($r | ConvertFrom-Json).choices[0].message.content
    }
    'anthropic' {
      $corpo = @{ model = $cfg.ia.modelo_anthropic; max_tokens = 4000; messages = @(@{ role = 'user'; content = $prompt }) } | ConvertTo-Json -Depth 10
      $r = Pedir 'https://api.anthropic.com/v1/messages' 'POST' $corpo @{ 'x-api-key' = $seg.chave_anthropic; 'anthropic-version' = '2023-06-01' }
      return ($r | ConvertFrom-Json).content[0].text
    }
    'ollama' {
      $corpo = @{ model = $cfg.ia.modelo_ollama; prompt = $prompt; stream = $false; format = 'json' } | ConvertTo-Json -Depth 10
      $r = Pedir 'http://localhost:11434/api/generate' 'POST' $corpo
      return ($r | ConvertFrom-Json).response
    }
    default { throw "Provedor de IA desconhecido: $prov" }
  }
}

$resumo = $null
if ($itens.Count -gt 0 -and $cfg.ia.provedor -ne 'nenhum') {
  try {
    $lista = for ($i = 0; $i -lt $itens.Count; $i++) {
      $n = $itens[$i]
      $origem = if ($n.oficial) { "FONTE OFICIAL $($n.estado): $($n.fonte)" } else { $n.fonte }
      $extra = if ($n.resumo) { " — $($n.resumo)" } else { '' }
      "[$i] ($origem) $($n.titulo)$extra"
    }
    Set-Content -Path "$base\ia_ultima_entrada.txt" -Value $lista -Encoding UTF8
    # Modelos leves às vezes devolvem lista vazia por acaso: tenta de novo antes de aceitar
    for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
      $texto = Chamar-IA ($cfg.ia.prompt + "`n`nMANCHETES:`n" + ($lista -join "`n"))
      Set-Content -Path "$base\ia_ultima_resposta.txt" -Value $texto -Encoding UTF8
      $json = $texto.Substring($texto.IndexOf('{'), $texto.LastIndexOf('}') - $texto.IndexOf('{') + 1)
      # Cada assunto traz os índices de todas as matérias sobre ele; a repercussão é o nº de veículos diferentes
      $resumo = @(($json | ConvertFrom-Json).itens | ForEach-Object {
        $idx = @(@($_.indices) + @($_.indice) | Where-Object { $_ -ne $null -and [int]$_ -ge 0 -and [int]$_ -lt $itens.Count } |
          ForEach-Object { [int]$_ } | Select-Object -Unique)
        if ($idx.Count -eq 0) { return }
        $grupo = @($idx | ForEach-Object { $itens[$_] })
        $principal = $grupo | Sort-Object @{ Expression = 'oficial'; Descending = $true }, @{ Expression = 'data'; Descending = $true } | Select-Object -First 1
        $_ | Add-Member -NotePropertyName noticias -NotePropertyValue $grupo -PassThru |
          Add-Member -NotePropertyName principal -NotePropertyValue $principal -PassThru |
          Add-Member -NotePropertyName veiculos -NotePropertyValue @($grupo | ForEach-Object { $_.fonte } | Select-Object -Unique).Count -PassThru
      })
      if ($resumo.Count -gt 0) { break }
    }
    Log "IA ($($cfg.ia.provedor)): $($resumo.Count) item(ns) relevante(s)."
  } catch {
    Log "IA falhou ($($_.Exception.Message)); enviando só a lista filtrada."
    $resumo = $null
  }
}

# ---------- 3. Monta o e-mail ----------
# Layout em tabelas com estilos inline: é o que Gmail, Outlook e celular exibem do mesmo jeito.
$hoje = Get-Date -Format 'dd/MM/yyyy'
$diasSemana = 'domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'
$dataExtenso = "$($diasSemana[[int](Get-Date).DayOfWeek]), $hoje"

$nomesUF = @{
  AC = 'Acre'; AL = 'Alagoas'; AP = 'Amapá'; AM = 'Amazonas'; BA = 'Bahia'; CE = 'Ceará'; DF = 'Distrito Federal'
  ES = 'Espírito Santo'; GO = 'Goiás'; MA = 'Maranhão'; MT = 'Mato Grosso'; MS = 'Mato Grosso do Sul'; MG = 'Minas Gerais'
  PA = 'Pará'; PB = 'Paraíba'; PR = 'Paraná'; PE = 'Pernambuco'; PI = 'Piauí'; RJ = 'Rio de Janeiro'; RN = 'Rio Grande do Norte'
  RS = 'Rio Grande do Sul'; RO = 'Rondônia'; RR = 'Roraima'; SC = 'Santa Catarina'; SP = 'São Paulo'; SE = 'Sergipe'; TO = 'Tocantins'
}
function NomeUF($uf) { if ($nomesUF.ContainsKey([string]$uf)) { $nomesUF[[string]$uf] } elseif ($uf) { $uf } else { 'Estado não informado' } }

$cor = @{ fundo = '#eef1f5'; azul = '#12355b'; destaque = '#2f7fd8'; texto = '#1f2933'; suave = '#6b7785'; borda = '#dde3ea'; verde = '#1a7f37'; creme = '#f5f8fc'; laranja = '#c2410c'; pessego = '#fff4ed' }

function Selo($n) {
  if ($n.oficial) { "<span style='display:inline-block;background:$($cor.verde);color:#fff;font-size:10px;font-weight:bold;letter-spacing:.5px;padding:2px 7px;border-radius:10px;margin-right:6px'>FONTE OFICIAL</span>" } else { '' }
}

function Rodape-Card($n) {
  @"
<tr><td style='padding:12px 20px 16px;border-top:1px solid $($cor.borda)'>
  <table role='presentation' width='100%' cellpadding='0' cellspacing='0'><tr>
    <td style='font-size:12px;color:$($cor.suave)'>$(Selo $n)$(Html $n.fonte) · $($n.data.ToString('dd/MM HH:mm'))</td>
    <td align='right' style='white-space:nowrap'><a href='$(Html $n.link)' style='font-size:13px;font-weight:bold;color:$($cor.destaque);text-decoration:none'>Ler notícia &rarr;</a></td>
  </tr></table>
</td></tr>
"@
}

function Card($corpo, $n, $faixa = $null) {
  if (-not $faixa) { $faixa = if ($n.oficial) { $cor.verde } else { $cor.destaque } }
  @"
<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='background:#fff;border:1px solid $($cor.borda);border-left:4px solid $faixa;border-radius:8px;margin:0 0 14px'>
$corpo
$(Rodape-Card $n)
</table>
"@
}

$blocos = New-Object System.Collections.Generic.List[string]
$total = 0
$estados = @()

function Titulo-Secao($texto, $detalhe, $corTitulo) {
  "<div style='margin:26px 0 10px;font-size:13px;font-weight:bold;letter-spacing:1px;color:$corTitulo;text-transform:uppercase'>$texto <span style='color:$($cor.suave);font-weight:normal;letter-spacing:0;text-transform:none'>· $detalhe</span></div>"
}

function Card-Assunto($r, $quente) {
  $n = $r.principal
  $selo = ''
  $tambem = ''
  if ($quente) {
    $selo = "<div style='margin-bottom:8px'><span style='display:inline-block;background:$($cor.pessego);color:$($cor.laranja);font-size:12px;font-weight:bold;padding:3px 10px;border-radius:12px'>&#128293; Repercutiu em $($r.veiculos) veículos</span> <span style='font-size:12px;color:$($cor.suave)'>$(Html (NomeUF $r.estado))</span></div>"
    $outros = @($r.noticias | Where-Object { $_.fonte -ne $n.fonte } | Sort-Object @{ Expression = 'oficial'; Descending = $true }, @{ Expression = 'data'; Descending = $true } |
      Group-Object fonte | ForEach-Object { $_.Group[0] } | Select-Object -First 4)
    if ($outros.Count -gt 0) {
      $links = ($outros | ForEach-Object { "<a href='$(Html $_.link)' style='color:$($cor.destaque);text-decoration:none'>$(Html $_.fonte)</a>" }) -join ' · '
      $tambem = "<tr><td style='padding:0 20px 14px;font-size:12px;color:$($cor.suave)'>Também em: $links</td></tr>"
    }
  }
  $corpo = @"
<tr><td style='padding:18px 20px 6px'>
  $selo
  <div style='font-size:17px;line-height:1.35;font-weight:bold;color:$($cor.texto)'>$(Html $r.manchete)</div>
</td></tr>
<tr><td style='padding:6px 20px 4px'>
  <div style='font-size:11px;font-weight:bold;letter-spacing:.8px;color:$($cor.destaque)'>O QUE MUDA</div>
  <div style='font-size:14px;line-height:1.5;color:$($cor.texto);margin-top:2px'>$(Html $r.o_que_muda)</div>
</td></tr>
<tr><td style='padding:8px 20px 14px'>
  <div style='background:$($cor.creme);border-radius:6px;padding:10px 12px'>
    <div style='font-size:11px;font-weight:bold;letter-spacing:.8px;color:$($cor.azul)'>COMO TE AFETA</div>
    <div style='font-size:14px;line-height:1.5;color:$($cor.texto);margin-top:2px'>$(Html $r.impacto)</div>
  </div>
</td></tr>
$tambem
"@
  $faixa = if ($quente) { $cor.laranja } else { $null }
  Card $corpo $n $faixa
}

if ($resumo -ne $null) {
  $total = $resumo.Count

  # Mais discutidos: assuntos cobertos por vários veículos diferentes
  $quentes = @($resumo | Where-Object { $_.veiculos -ge $cfg.mais_discutidos_minimo } |
    Sort-Object veiculos -Descending | Select-Object -First $cfg.mais_discutidos_max)
  if ($quentes.Count -gt 0) {
    $qtd = if ($quentes.Count -eq 1) { '1 assunto' } else { "$($quentes.Count) assuntos" }
    $blocos.Add((Titulo-Secao '&#128293; Mais discutidos' $qtd $cor.laranja))
    foreach ($r in $quentes) { $blocos.Add((Card-Assunto $r $true)) }
  }

  $demais = @($resumo | Where-Object { $quentes -notcontains $_ })
  $grupos = @($demais | Group-Object { NomeUF $_.estado } |
    Sort-Object @{ Expression = { $_.Name -eq 'Estado não informado' } }, Name)
  $estados = @($resumo | ForEach-Object { NomeUF $_.estado } | Select-Object -Unique |
    Sort-Object @{ Expression = { $_ -eq 'Estado não informado' } }, { $_ })
  foreach ($grupo in $grupos) {
    $qtd = if ($grupo.Count -eq 1) { '1 decisão' } else { "$($grupo.Count) decisões" }
    $blocos.Add((Titulo-Secao (Html $grupo.Name) $qtd $cor.azul))
    foreach ($r in $grupo.Group) { $blocos.Add((Card-Assunto $r $false)) }
  }
} else {
  $total = $itens.Count
  foreach ($n in $itens) {
    $resumoHtml = if ($n.resumo) { "<div style='font-size:14px;line-height:1.5;color:$($cor.suave);margin-top:6px'>$(Html $n.resumo)</div>" } else { '' }
    $corpo = "<tr><td style='padding:18px 20px 14px'><div style='font-size:16px;line-height:1.35;font-weight:bold;color:$($cor.texto)'>$(Html $n.titulo)</div>$resumoHtml</td></tr>"
    $blocos.Add((Card $corpo $n))
  }
}

$vazio = ($blocos.Count -eq 0)
if ($vazio) {
  $blocos.Add("<div style='background:#fff;border:1px solid $($cor.borda);border-radius:8px;padding:28px 20px;text-align:center;font-size:15px;color:$($cor.suave)'>Nenhuma lei ou decisão estadual nova desde o último boletim.</div>")
}

$plural = if ($total -eq 1) { '1 decisão' } else { "$total decisões" }
$linhaResumo = if ($vazio) { 'Sem novidades hoje' } elseif ($estados.Count -gt 0) { "$plural em $($estados.Count) " + $(if ($estados.Count -eq 1) { 'estado' } else { 'estados' }) } else { "$total notícias filtradas" }
$chips = ($estados | ForEach-Object { "<span style='display:inline-block;background:rgba(255,255,255,.14);color:#fff;font-size:12px;padding:3px 10px;border-radius:12px;margin:6px 6px 0 0'>$(Html $_)</span>" }) -join ''

# A mesma página serve para o e-mail e para o site; o site ganha cabeçalho de navegação e ícone de app
function Pagina($site = $false, $prefixo = '') {
  $head = ''
  $nav = ''
  if ($site) {
    $head = @"
<title>Boletim Estadual · $hoje</title>
<meta name='description' content='Leis e decisões dos estados, explicadas sem juridiquês. $linhaResumo.'>
<meta property='og:title' content='Boletim Estadual · $hoje'>
<meta property='og:description' content='$linhaResumo'>
<meta name='theme-color' content='$($cor.azul)'>
<link rel='manifest' href='${prefixo}manifest.webmanifest'>
<link rel='icon' href='${prefixo}icone.svg' type='image/svg+xml'>
<link rel='apple-touch-icon' href='${prefixo}icone-180.png'>
<base target='_blank'>
"@
    $nav = "<tr><td style='padding:0 4px 12px;font-size:13px'><a href='${prefixo}index.html' target='_self' style='color:$($cor.azul);font-weight:bold;text-decoration:none'>Boletim Estadual</a><span style='float:right'><a href='${prefixo}index.html' target='_self' style='color:$($cor.destaque);text-decoration:none'>Hoje</a> &nbsp;·&nbsp; <a href='${prefixo}arquivo.html' target='_self' style='color:$($cor.destaque);text-decoration:none'>Edições anteriores</a></span></td></tr>"
  }
  @"
<!DOCTYPE html>
<html lang='pt-BR'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>$head</head>
<body style='margin:0;padding:0;background:$($cor.fundo);font-family:Segoe UI,Helvetica,Arial,sans-serif'>
<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='background:$($cor.fundo)'><tr><td align='center' style='padding:24px 12px'>
<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='max-width:640px'>
$nav

<tr><td style='background:$($cor.azul);border-radius:10px 10px 0 0;padding:26px 24px 22px'>
  <div style='font-size:11px;font-weight:bold;letter-spacing:2px;color:#9fc3ee'>BOLETIM ESTADUAL</div>
  <div style='font-size:24px;font-weight:bold;color:#fff;margin-top:6px'>Leis e decisões dos estados</div>
  <div style='font-size:14px;color:#d6e4f5;margin-top:4px'>$dataExtenso · $linhaResumo</div>
  <div style='margin-top:8px'>$chips</div>
</td></tr>

<tr><td style='background:$($cor.creme);border:1px solid $($cor.borda);border-top:0;border-radius:0 0 10px 10px;padding:12px 24px;font-size:13px;color:$($cor.suave)'>
  Só o que governadores e assembleias estaduais decidiram. Federal e municipal ficam de fora.
</td></tr>

<tr><td style='padding:4px 0 0'>
$($blocos -join "`n")
</td></tr>

<tr><td style='padding:18px 8px 8px;font-size:12px;line-height:1.6;color:$($cor.suave);text-align:center'>
  Resumos feitos automaticamente a partir das manchetes. Confira a fonte antes de tomar qualquer decisão.<br>
  <span style='color:$($cor.verde);font-weight:bold'>&#9679;</span> Fonte oficial (governo ou assembleia) &nbsp; <span style='color:$($cor.destaque);font-weight:bold'>&#9679;</span> Imprensa
</td></tr>

</table>
</td></tr></table>
</body></html>
"@
}

$corpoHtml = Pagina

# ---------- 4. Site ----------
# Cada dia com novidade vira uma edição em edicoes/AAAA-MM-DD.html; index.html é sempre a mais recente.
function Gerar-Site($pasta) {
  New-Item -ItemType Directory -Force -Path "$pasta\edicoes" | Out-Null
  Copy-Item "$base\site-base\*" $pasta -Force
  $dia = Get-Date -Format 'yyyy-MM-dd'
  Set-Content -Path "$pasta\edicoes\$dia.html" -Value (Pagina $true '../') -Encoding UTF8
  Set-Content -Path "$pasta\index.html" -Value (Pagina $true '') -Encoding UTF8

  # Índice das edições: guarda a linha-resumo e as primeiras manchetes de cada dia
  $indiceArq = "$pasta\edicoes.json"
  $edicoes = @()
  if (Test-Path $indiceArq) { $edicoes = @((Ler-Json $indiceArq) | Where-Object { $_.dia -ne $dia }) }
  $manchetes = if ($resumo -ne $null) { @($resumo | Sort-Object veiculos -Descending | Select-Object -First 3 | ForEach-Object { $_.manchete }) } else { @($itens | Select-Object -First 3 | ForEach-Object { $_.titulo }) }
  $edicoes = @([pscustomobject]@{ dia = $dia; data = $dataExtenso; resumo = $linhaResumo; manchetes = $manchetes }) + $edicoes | Sort-Object dia -Descending
  ConvertTo-Json -InputObject @($edicoes) -Depth 5 | Set-Content -Path $indiceArq -Encoding UTF8

  $linhas = foreach ($e in $edicoes) {
    $lista = ($e.manchetes | ForEach-Object { "<li style='margin:3px 0'>$(Html $_)</li>" }) -join ''
    @"
<a href='edicoes/$($e.dia).html' target='_self' style='display:block;text-decoration:none;background:#fff;border:1px solid $($cor.borda);border-left:4px solid $($cor.destaque);border-radius:8px;padding:16px 20px;margin:0 0 12px;color:$($cor.texto)'>
  <div style='font-size:16px;font-weight:bold;color:$($cor.azul)'>$(Html $e.data)</div>
  <div style='font-size:13px;color:$($cor.suave);margin-top:2px'>$(Html $e.resumo)</div>
  <ul style='font-size:14px;line-height:1.4;margin:8px 0 0;padding-left:18px'>$lista</ul>
</a>
"@
  }
  $arquivo = @"
<!DOCTYPE html>
<html lang='pt-BR'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Edições anteriores · Boletim Estadual</title><meta name='theme-color' content='$($cor.azul)'>
<link rel='manifest' href='manifest.webmanifest'><link rel='icon' href='icone.svg' type='image/svg+xml'><link rel='apple-touch-icon' href='icone-180.png'></head>
<body style='margin:0;padding:24px 12px;background:$($cor.fundo);font-family:Segoe UI,Helvetica,Arial,sans-serif'>
<div style='max-width:640px;margin:0 auto'>
  <div style='padding:0 4px 12px;font-size:13px'><a href='index.html' style='color:$($cor.azul);font-weight:bold;text-decoration:none'>Boletim Estadual</a><span style='float:right'><a href='index.html' style='color:$($cor.destaque);text-decoration:none'>Hoje</a></span></div>
  <div style='background:$($cor.azul);border-radius:10px;padding:22px 24px;margin-bottom:18px'>
    <div style='font-size:11px;font-weight:bold;letter-spacing:2px;color:#9fc3ee'>BOLETIM ESTADUAL</div>
    <div style='font-size:22px;font-weight:bold;color:#fff;margin-top:6px'>Edições anteriores</div>
  </div>
  $($linhas -join "`n")
</div>
</body></html>
"@
  Set-Content -Path "$pasta\arquivo.html" -Value $arquivo -Encoding UTF8
}

# ---------- 5. Envia ----------
if ($Simular) {
  $previa = "$base\previa.html"
  Set-Content -Path $previa -Value $corpoHtml -Encoding UTF8
  if (-not $vazio) { Gerar-Site "$base\previa-site" }
  Log "Simulação: prévia gravada em $previa e previa-site\ (nada enviado nem publicado)."
  return
}

if ($vazio -and -not $cfg.enviar_quando_vazio) { Log "Nada novo; e-mail e site não atualizados."; return }

if (-not $vazio) { Gerar-Site "$base\docs"; Log "Site atualizado em docs\." }

$smtp = New-Object Net.Mail.SmtpClient($cfg.email.servidor_smtp, [int]$cfg.email.porta)
$smtp.EnableSsl = $true
$smtp.Credentials = New-Object Net.NetworkCredential($emailConta, $seg.senha_email)
$msg = New-Object Net.Mail.MailMessage
$msg.From = $emailConta
foreach ($para in ($emailPara -split '[,;]')) { if ($para.Trim()) { $msg.To.Add($para.Trim()) } }
$msg.Subject = "$($cfg.email.assunto) · $hoje"
$msg.SubjectEncoding = [Text.Encoding]::UTF8
$msg.Body = $corpoHtml
$msg.BodyEncoding = [Text.Encoding]::UTF8
$msg.IsBodyHtml = $true
$smtp.Send($msg)
Log "E-mail enviado."

# Marca como lido só depois de enviar; esquece o que tem mais de 30 dias
$agora = Get-Date
foreach ($n in $itens) { $vistos[$n.chave] = $agora.ToString('o') }
$manter = @{}
foreach ($k in $vistos.Keys) { if ([datetime]$vistos[$k] -gt $agora.AddDays(-30)) { $manter[$k] = $vistos[$k] } }
$manter | ConvertTo-Json | Set-Content -Path $vistosArq -Encoding UTF8
