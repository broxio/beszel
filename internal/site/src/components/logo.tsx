import { cn } from "@/lib/utils"
import logoUrl from "@/assets/beszel-duck.png"

export function Logo({ className }: { className?: string }) {
	return (
		// Raster badge logo. Grayscale by default, full color on hover (the
		// closest raster equivalent of the original wordmark's black→gradient
		// cross-fade — a true mono→color recolor would require a vector SVG).
		// hover: works standalone; group-hover: also fires from a parent `.group`.
		<img
			src={logoUrl}
			alt="beszel"
			className={cn(
				"w-auto grayscale transition-[filter] duration-250 ease-out hover:grayscale-0 group-hover:grayscale-0",
				className,
			)}
		/>
	)
}
