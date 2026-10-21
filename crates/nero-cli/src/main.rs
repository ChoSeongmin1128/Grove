fn main() {
    std::process::exit(nero_cli::cli::run(std::env::args_os().skip(1)));
}
