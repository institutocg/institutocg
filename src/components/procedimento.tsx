"use client";

import { useId } from "react";

/**
 * Campo de procedimento com digitação livre. A lista cadastrada aparece como
 * sugestão enquanto se digita, mas nunca impede escrever outro procedimento.
 */
export function CampoProcedimento({
  id,
  name,
  value,
  defaultValue,
  onChange,
  sugestoes,
  placeholder = "Escreva ou escolha",
  className,
  "aria-describedby": descritoPor,
}: {
  "aria-describedby"?: string;
  id?: string;
  name?: string;
  value?: string;
  defaultValue?: string;
  onChange?: (v: string) => void;
  sugestoes: { nome: string }[];
  placeholder?: string;
  className: string;
}) {
  const lista = useId();
  return (
    <>
      <input
        id={id}
        name={name}
        aria-describedby={descritoPor}
        list={lista}
        value={value}
        defaultValue={defaultValue}
        onChange={onChange ? (e) => onChange(e.target.value) : undefined}
        maxLength={120}
        autoComplete="off"
        placeholder={placeholder}
        className={className}
      />
      <datalist id={lista}>
        {sugestoes.map((s) => (
          <option key={s.nome} value={s.nome} />
        ))}
      </datalist>
    </>
  );
}
