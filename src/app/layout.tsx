import type { Metadata, Viewport } from "next";
import { Cormorant_Garamond, Inter } from "next/font/google";
import "./globals.css";

const titulo = Cormorant_Garamond({
  subsets: ["latin"],
  weight: ["500", "600"],
  variable: "--fonte-titulo",
});
const texto = Inter({ subsets: ["latin"], variable: "--fonte-texto" });

export const metadata: Metadata = {
  title: "Instituto CG",
  description: "Relacionamento e organização comercial do Instituto CG",
};

export const viewport: Viewport = { themeColor: "#faf8f4" };

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="pt-BR" className={`${titulo.variable} ${texto.variable} h-full`}>
      <body className="min-h-full">{children}</body>
    </html>
  );
}
