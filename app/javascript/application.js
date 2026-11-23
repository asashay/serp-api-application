import { Application } from "@hotwired/stimulus"
import PlaygroundController from "playground_controller"

Application.start().register("playground", PlaygroundController)
