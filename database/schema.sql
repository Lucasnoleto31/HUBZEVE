-- =============================================================================
-- ZeveHub — Schema Completo
-- Execute no Supabase SQL Editor (em ordem, do topo ao fim)
-- =============================================================================


-- =============================================================================
-- 1. EXTENSIONS
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- =============================================================================
-- 2. ENUMS
-- =============================================================================
CREATE TYPE user_role        AS ENUM ('cliente', 'assessor', 'admin');
CREATE TYPE trade_side       AS ENUM ('C', 'V');
CREATE TYPE upload_status    AS ENUM ('processing', 'done', 'error');
CREATE TYPE comment_visibility AS ENUM ('shared', 'private');
CREATE TYPE notification_type AS ENUM (
  'novo_comentario',
  'upload_concluido',
  'upload_erro',
  'feedback_assessor',
  'aviso_sistema'
);


-- =============================================================================
-- 3. FUNÇÃO: atualiza updated_at automaticamente
-- =============================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 4. PLANOS
-- =============================================================================
CREATE TABLE planos (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome             TEXT NOT NULL,
  descricao        TEXT,
  max_uploads_mes  INT  NOT NULL DEFAULT 10,
  features         JSONB NOT NULL DEFAULT '[]',
  ativo            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed: plano padrão
INSERT INTO planos (nome, descricao, max_uploads_mes, features) VALUES
  ('Conveniado', 'Acesso completo ao ZeveHub — benefício incluso na assessoria.', 100,
   '["dashboard_completo","upload_csv","heatmap_horarios","feedback_assessor","historico_operacoes"]');


-- =============================================================================
-- 5. PROFILES (extensão do auth.users do Supabase)
-- =============================================================================
CREATE TABLE profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     TEXT NOT NULL DEFAULT '',
  email         TEXT NOT NULL DEFAULT '',
  role          user_role NOT NULL DEFAULT 'cliente',
  avatar_url    TEXT,
  phone         TEXT,
  conta_profit  TEXT,
  plano_id      UUID REFERENCES planos(id) ON DELETE SET NULL,
  ativo         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Cria perfil automaticamente ao registrar novo usuário
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  default_plan UUID;
BEGIN
  SELECT id INTO default_plan FROM planos WHERE nome = 'Conveniado' LIMIT 1;

  INSERT INTO profiles (id, full_name, email, role, plano_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.email, ''),
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'cliente'),
    default_plan
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- =============================================================================
-- 6. VÍNCULOS: ASSESSOR → CLIENTES
-- =============================================================================
CREATE TABLE assessor_cliente (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessor_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  cliente_id   UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  ativo        BOOLEAN NOT NULL DEFAULT TRUE,
  criado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (assessor_id, cliente_id)
);

CREATE INDEX idx_assessor_cliente_assessor ON assessor_cliente(assessor_id);
CREATE INDEX idx_assessor_cliente_cliente  ON assessor_cliente(cliente_id);


-- =============================================================================
-- 7. UPLOADS DE CSV
-- =============================================================================
CREATE TABLE uploads (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  nome_arquivo    TEXT NOT NULL,
  storage_path    TEXT NOT NULL,
  periodo_inicio  DATE,
  periodo_fim     DATE,
  conta_profit    TEXT,
  titular         TEXT,
  total_trades    INT NOT NULL DEFAULT 0,
  status          upload_status NOT NULL DEFAULT 'processing',
  erro_msg        TEXT,
  processado_em   TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_uploads_cliente    ON uploads(cliente_id, created_at DESC);
CREATE INDEX idx_uploads_status     ON uploads(status);
CREATE INDEX idx_uploads_periodo    ON uploads(cliente_id, periodo_inicio, periodo_fim);


-- =============================================================================
-- 8. TRADES (cada linha do CSV = 1 trade)
-- =============================================================================
CREATE TABLE trades (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  upload_id            UUID NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  cliente_id           UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  -- Dados do CSV
  ativo                TEXT NOT NULL,
  abertura             TIMESTAMPTZ NOT NULL,
  fechamento           TIMESTAMPTZ NOT NULL,
  tempo_operacao_seg   INT,
  lado                 trade_side NOT NULL,
  qtd_compra           INT,
  qtd_venda            INT,
  preco_compra         NUMERIC(12,2),
  preco_venda          NUMERIC(12,2),
  resultado_reais      NUMERIC(12,2) NOT NULL DEFAULT 0,
  resultado_pontos     NUMERIC(12,4),
  drawdown             NUMERIC(12,2),
  ganho_max            NUMERIC(12,2),
  perda_max            NUMERIC(12,2),
  total_acumulado      NUMERIC(12,2),

  -- Campos calculados no parse
  data_trade           DATE NOT NULL,
  hora_abertura        TIME,
  duracao_minutos      NUMERIC(8,2),
  is_winner            BOOLEAN NOT NULL DEFAULT FALSE,

  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trades_cliente_data  ON trades(cliente_id, data_trade DESC);
CREATE INDEX idx_trades_upload        ON trades(upload_id);
CREATE INDEX idx_trades_ativo         ON trades(cliente_id, ativo);
CREATE INDEX idx_trades_abertura_hora ON trades(cliente_id, hora_abertura);
CREATE INDEX idx_trades_lado          ON trades(cliente_id, lado);


-- =============================================================================
-- 9. MÉTRICAS DIÁRIAS (cache calculado por dia)
-- =============================================================================
CREATE TABLE metricas_diarias (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  data                DATE NOT NULL,

  total_trades        INT NOT NULL DEFAULT 0,
  trades_ganho        INT NOT NULL DEFAULT 0,
  trades_perda        INT NOT NULL DEFAULT 0,
  pnl_reais           NUMERIC(12,2) NOT NULL DEFAULT 0,
  pnl_pontos          NUMERIC(12,4),
  taxa_acerto         NUMERIC(5,2),
  payoff              NUMERIC(8,4),
  fator_lucro         NUMERIC(8,4),
  drawdown_max        NUMERIC(12,2),
  ganho_medio         NUMERIC(12,2),
  perda_media         NUMERIC(12,2),
  duracao_media_min   NUMERIC(8,2),
  maior_ganho         NUMERIC(12,2),
  maior_perda         NUMERIC(12,2),

  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cliente_id, data)
);

CREATE TRIGGER trg_metricas_diarias_updated_at
  BEFORE UPDATE ON metricas_diarias
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_metricas_diarias_cliente ON metricas_diarias(cliente_id, data DESC);


-- =============================================================================
-- 10. MÉTRICAS MENSAIS (cache calculado por mês)
-- =============================================================================
CREATE TABLE metricas_mensais (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  ano                 INT NOT NULL,
  mes                 INT NOT NULL CHECK (mes BETWEEN 1 AND 12),

  total_trades        INT NOT NULL DEFAULT 0,
  dias_operados       INT NOT NULL DEFAULT 0,
  trades_ganho        INT NOT NULL DEFAULT 0,
  trades_perda        INT NOT NULL DEFAULT 0,
  pnl_reais           NUMERIC(12,2) NOT NULL DEFAULT 0,
  taxa_acerto         NUMERIC(5,2),
  payoff              NUMERIC(8,4),
  fator_lucro         NUMERIC(8,4),
  drawdown_max        NUMERIC(12,2),
  melhor_dia          NUMERIC(12,2),
  pior_dia            NUMERIC(12,2),
  streak_ganho_max    INT NOT NULL DEFAULT 0,
  streak_perda_max    INT NOT NULL DEFAULT 0,

  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cliente_id, ano, mes)
);

CREATE TRIGGER trg_metricas_mensais_updated_at
  BEFORE UPDATE ON metricas_mensais
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_metricas_mensais_cliente ON metricas_mensais(cliente_id, ano DESC, mes DESC);


-- =============================================================================
-- 11. COMENTÁRIOS DO ASSESSOR
-- =============================================================================
CREATE TABLE comentarios (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessor_id   UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  cliente_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  upload_id     UUID REFERENCES uploads(id) ON DELETE SET NULL,
  trade_id      UUID REFERENCES trades(id)  ON DELETE SET NULL,
  conteudo      TEXT NOT NULL,
  visibilidade  comment_visibility NOT NULL DEFAULT 'shared',
  pinned        BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_comentarios_updated_at
  BEFORE UPDATE ON comentarios
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_comentarios_cliente  ON comentarios(cliente_id, created_at DESC);
CREATE INDEX idx_comentarios_assessor ON comentarios(assessor_id, created_at DESC);


-- =============================================================================
-- 12. NOTIFICAÇÕES
-- =============================================================================
CREATE TABLE notificacoes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tipo       notification_type NOT NULL,
  titulo     TEXT NOT NULL,
  mensagem   TEXT,
  lida       BOOLEAN NOT NULL DEFAULT FALSE,
  link       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notificacoes_user ON notificacoes(user_id, lida, created_at DESC);


-- =============================================================================
-- 13. ROW LEVEL SECURITY (RLS)
-- =============================================================================

-- ── Helper: retorna o role do usuário atual ──
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS user_role AS $$
  SELECT role FROM profiles WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ── Helper: verifica se o assessor tem vínculo com o cliente ──
CREATE OR REPLACE FUNCTION is_my_cliente(p_cliente_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM assessor_cliente
    WHERE assessor_id = auth.uid()
      AND cliente_id  = p_cliente_id
      AND ativo = TRUE
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;


-- ──────────────────────────────────────────
-- PROFILES
-- ──────────────────────────────────────────
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Leitura: próprio perfil
CREATE POLICY "profiles: leitura própria"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

-- Leitura: assessor vê seus clientes
CREATE POLICY "profiles: assessor vê clientes"
  ON profiles FOR SELECT
  USING (
    get_my_role() = 'assessor'
    AND is_my_cliente(id)
  );

-- Leitura: admin vê todos
CREATE POLICY "profiles: admin vê todos"
  ON profiles FOR SELECT
  USING (get_my_role() = 'admin');

-- Escrita: próprio perfil (exceto role — só admin muda role)
CREATE POLICY "profiles: atualiza próprio"
  ON profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = (SELECT role FROM profiles WHERE id = auth.uid())
  );

-- Escrita: admin pode tudo
CREATE POLICY "profiles: admin pode tudo"
  ON profiles FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- PLANOS
-- ──────────────────────────────────────────
ALTER TABLE planos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "planos: todos leem"
  ON planos FOR SELECT
  USING (TRUE);

CREATE POLICY "planos: admin gerencia"
  ON planos FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- ASSESSOR_CLIENTE
-- ──────────────────────────────────────────
ALTER TABLE assessor_cliente ENABLE ROW LEVEL SECURITY;

CREATE POLICY "assessor_cliente: assessor vê seus vínculos"
  ON assessor_cliente FOR SELECT
  USING (assessor_id = auth.uid() OR cliente_id = auth.uid());

CREATE POLICY "assessor_cliente: admin gerencia"
  ON assessor_cliente FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- UPLOADS
-- ──────────────────────────────────────────
ALTER TABLE uploads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "uploads: cliente vê os próprios"
  ON uploads FOR SELECT
  USING (cliente_id = auth.uid());

CREATE POLICY "uploads: cliente cria"
  ON uploads FOR INSERT
  WITH CHECK (cliente_id = auth.uid());

CREATE POLICY "uploads: assessor vê de seus clientes"
  ON uploads FOR SELECT
  USING (
    get_my_role() = 'assessor'
    AND is_my_cliente(cliente_id)
  );

CREATE POLICY "uploads: admin vê todos"
  ON uploads FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- TRADES
-- ──────────────────────────────────────────
ALTER TABLE trades ENABLE ROW LEVEL SECURITY;

CREATE POLICY "trades: cliente vê os próprios"
  ON trades FOR SELECT
  USING (cliente_id = auth.uid());

CREATE POLICY "trades: cliente insere"
  ON trades FOR INSERT
  WITH CHECK (cliente_id = auth.uid());

CREATE POLICY "trades: assessor vê de seus clientes"
  ON trades FOR SELECT
  USING (
    get_my_role() = 'assessor'
    AND is_my_cliente(cliente_id)
  );

CREATE POLICY "trades: admin vê todos"
  ON trades FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- MÉTRICAS DIÁRIAS
-- ──────────────────────────────────────────
ALTER TABLE metricas_diarias ENABLE ROW LEVEL SECURITY;

CREATE POLICY "metricas_diarias: cliente vê as próprias"
  ON metricas_diarias FOR SELECT
  USING (cliente_id = auth.uid());

CREATE POLICY "metricas_diarias: assessor vê de seus clientes"
  ON metricas_diarias FOR SELECT
  USING (
    get_my_role() = 'assessor'
    AND is_my_cliente(cliente_id)
  );

CREATE POLICY "metricas_diarias: sistema escreve (service_role)"
  ON metricas_diarias FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- MÉTRICAS MENSAIS
-- ──────────────────────────────────────────
ALTER TABLE metricas_mensais ENABLE ROW LEVEL SECURITY;

CREATE POLICY "metricas_mensais: cliente vê as próprias"
  ON metricas_mensais FOR SELECT
  USING (cliente_id = auth.uid());

CREATE POLICY "metricas_mensais: assessor vê de seus clientes"
  ON metricas_mensais FOR SELECT
  USING (
    get_my_role() = 'assessor'
    AND is_my_cliente(cliente_id)
  );

CREATE POLICY "metricas_mensais: sistema escreve (service_role)"
  ON metricas_mensais FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- COMENTÁRIOS
-- ──────────────────────────────────────────
ALTER TABLE comentarios ENABLE ROW LEVEL SECURITY;

-- Cliente vê os comentários compartilhados para ele
CREATE POLICY "comentarios: cliente vê os próprios"
  ON comentarios FOR SELECT
  USING (
    cliente_id = auth.uid()
    AND visibilidade = 'shared'
  );

-- Assessor vê e gerencia os seus comentários
CREATE POLICY "comentarios: assessor gerencia os seus"
  ON comentarios FOR ALL
  USING (
    assessor_id = auth.uid()
    AND get_my_role() = 'assessor'
  );

-- Assessor só cria comentários sobre seus clientes
CREATE POLICY "comentarios: assessor cria sobre seus clientes"
  ON comentarios FOR INSERT
  WITH CHECK (
    assessor_id = auth.uid()
    AND get_my_role() = 'assessor'
    AND is_my_cliente(cliente_id)
  );

CREATE POLICY "comentarios: admin vê todos"
  ON comentarios FOR ALL
  USING (get_my_role() = 'admin');


-- ──────────────────────────────────────────
-- NOTIFICAÇÕES
-- ──────────────────────────────────────────
ALTER TABLE notificacoes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notificacoes: usuário vê as próprias"
  ON notificacoes FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "notificacoes: usuário marca como lida"
  ON notificacoes FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "notificacoes: sistema cria (service_role)"
  ON notificacoes FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "notificacoes: admin vê todas"
  ON notificacoes FOR ALL
  USING (get_my_role() = 'admin');


-- =============================================================================
-- 14. STORAGE BUCKETS
-- =============================================================================

-- Bucket privado para os CSVs
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'csv-uploads',
  'csv-uploads',
  FALSE,
  10485760,  -- 10 MB
  ARRAY['text/csv', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream']
);

-- Política de storage: cliente sobe e lê apenas os seus arquivos
CREATE POLICY "storage: cliente faz upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'csv-uploads'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "storage: cliente lê os próprios"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'csv-uploads'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Assessor lê arquivos dos seus clientes
CREATE POLICY "storage: assessor lê de seus clientes"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'csv-uploads'
    AND is_my_cliente(((storage.foldername(name))[1])::UUID)
  );

-- Admin acessa tudo
CREATE POLICY "storage: admin acessa tudo"
  ON storage.objects FOR ALL
  USING (
    bucket_id = 'csv-uploads'
    AND get_my_role() = 'admin'
  );


-- =============================================================================
-- 15. VIEW AUXILIAR: resumo de clientes para o painel do assessor
-- =============================================================================
CREATE OR REPLACE VIEW vw_clientes_assessor AS
SELECT
  ac.assessor_id,
  p.id                AS cliente_id,
  p.full_name,
  p.email,
  p.conta_profit,
  p.ativo,
  -- Métricas do mês atual
  mm.pnl_reais        AS pnl_mes_atual,
  mm.taxa_acerto      AS taxa_acerto_mes,
  mm.total_trades     AS trades_mes,
  mm.drawdown_max     AS drawdown_mes,
  -- Último upload
  (SELECT created_at FROM uploads u
   WHERE u.cliente_id = p.id
   ORDER BY created_at DESC LIMIT 1) AS ultimo_upload
FROM assessor_cliente ac
JOIN profiles p ON p.id = ac.cliente_id
LEFT JOIN metricas_mensais mm ON
  mm.cliente_id = p.id
  AND mm.ano  = EXTRACT(YEAR  FROM NOW())::INT
  AND mm.mes  = EXTRACT(MONTH FROM NOW())::INT
WHERE ac.ativo = TRUE;


-- =============================================================================
-- FIM DO SCHEMA
-- =============================================================================
