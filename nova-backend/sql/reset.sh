#!/usr/bin/env bash
# Recrea la base 'nova' y carga todos los scripts en orden (solo para pruebas).
S="psql -h ${PGHOST:-/tmp/pgw} -p ${PGPORT:-5433} -U postgres -v ON_ERROR_STOP=1 -q"
$S -c "drop database if exists nova" -c "create database nova" 2>/dev/null
for f in 01_schema 02_functions 03_api_rls 04_usuarios_recuperacion 05_entregas 06_pagos; do [ -f $f.sql ] && { $S -d nova -f $f.sql 2>&1 | grep -v NOTICE || true; }; done
