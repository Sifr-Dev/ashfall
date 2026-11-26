SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ashfall_erasure_receipts_row_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ashfall_erasure_receipts_row_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'erasure_receipts is append-only (% rejected)', TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: ashfall_erasure_receipts_truncate_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ashfall_erasure_receipts_truncate_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM erasure_receipts) THEN
    RAISE EXCEPTION 'erasure_receipts holds evidence and cannot be truncated'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NULL;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: erasure_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.erasure_receipts (
    id bigint NOT NULL,
    subject_token character varying NOT NULL,
    model character varying CONSTRAINT erasure_receipts_model_name_not_null NOT NULL,
    schema_fingerprint character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    actions jsonb DEFAULT '[]'::jsonb NOT NULL,
    completed_at timestamp(6) without time zone NOT NULL,
    fingerprint character varying NOT NULL,
    signature character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT erasure_receipts_actions_array CHECK ((jsonb_typeof(actions) = 'array'::text)),
    CONSTRAINT erasure_receipts_fingerprint_format CHECK (((fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT erasure_receipts_idempotency_key_format CHECK (((idempotency_key)::text ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$'::text)),
    CONSTRAINT erasure_receipts_schema_fingerprint_format CHECK (((schema_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT erasure_receipts_signature_format CHECK (((signature)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT erasure_receipts_subject_token_format CHECK (((subject_token)::text ~ '^ashfall:[0-9a-f]{64}$'::text)),
    CONSTRAINT erasure_receipts_model_format CHECK (((model)::text ~ '^[A-Z][A-Za-z0-9_:]*$'::text))
);


--
-- Name: erasure_receipts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.erasure_receipts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: erasure_receipts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.erasure_receipts_id_seq OWNED BY public.erasure_receipts.id;


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    body text,
    token character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notes_id_seq OWNED BY public.notes.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email character varying,
    name character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    subject_ref character varying NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: erasure_receipts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_receipts ALTER COLUMN id SET DEFAULT nextval('public.erasure_receipts_id_seq'::regclass);


--
-- Name: notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes ALTER COLUMN id SET DEFAULT nextval('public.notes_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: erasure_receipts erasure_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_receipts
    ADD CONSTRAINT erasure_receipts_pkey PRIMARY KEY (id);


--
-- Name: notes notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: index_erasure_receipts_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_erasure_receipts_on_idempotency_key ON public.erasure_receipts USING btree (idempotency_key);


--
-- Name: index_erasure_receipts_on_plan_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_erasure_receipts_on_plan_key ON public.erasure_receipts USING btree (subject_token, model, schema_fingerprint);


--
-- Name: index_notes_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_user_id ON public.notes USING btree (user_id);


--
-- Name: index_users_on_subject_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_subject_ref ON public.users USING btree (subject_ref);


--
-- Name: erasure_receipts erasure_receipts_row_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER erasure_receipts_row_append_only BEFORE DELETE OR UPDATE ON public.erasure_receipts FOR EACH ROW EXECUTE FUNCTION public.ashfall_erasure_receipts_row_append_only();


--
-- Name: erasure_receipts erasure_receipts_truncate_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER erasure_receipts_truncate_guard BEFORE TRUNCATE ON public.erasure_receipts FOR EACH STATEMENT EXECUTE FUNCTION public.ashfall_erasure_receipts_truncate_guard();


--
-- Name: notes fk_rails_7f2323ad43; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_7f2323ad43 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261126050500'),
('20261126043500'),
('20261126001726'),
('20261125124840'),
('20261125124839');

