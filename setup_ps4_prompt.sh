# shellcheck disable=all
autoload -U colors && colors
function enhanced_ps4() {
    PS4=$'\n%F{blue}+%N:%f%F{yellow}%i>%f %F{%(?.green.red)}[%?]%f \n%F{yellow}>>>%f '
}
enhanced_ps4
