interface FooterProps {
  count: number;
  total: number;
  leader: string;
}

export function Footer({ count, total, leader }: FooterProps) {
  return (
    <footer className="footer">
      <span style={{ fontVariantNumeric: "tabular-nums" }}>
        {count === total
          ? `${total} keybindings`
          : `${count} of ${total} keybindings`}
      </span>
      {" · "}
      <span>Leader = <kbd>{leader}</kbd></span>
      {" · "}
      <span>AstroNvim v5</span>
    </footer>
  );
}
