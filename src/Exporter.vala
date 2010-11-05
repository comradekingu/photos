/* Copyright 2010 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Exporter : Object {
    public enum Overwrite {
        YES,
        NO,
        CANCEL,
        REPLACE_ALL
    }
    
    public delegate void CompletionCallback(Exporter exporter);
    
    public delegate Overwrite OverwriteCallback(Exporter exporter, File file);
    
    public delegate bool ExportFailedCallback(Exporter exporter, File file, int remaining, 
        Error err);
    
    private class ExportJob : BackgroundJob {
        public MediaSource media;
        public File dest;
        public Scaling? scaling;
        public Jpeg.Quality? quality;
        public PhotoFileFormat? format;
        public Error? err = null;
        
        public ExportJob(Exporter owner, MediaSource media, File dest, Scaling? scaling, 
            Jpeg.Quality? quality, PhotoFileFormat? format, Cancellable cancellable) {
            base (owner, owner.on_exported, cancellable, owner.on_export_cancelled);
            
            assert(media is Photo || media is Video);
            
            this.media = media;
            this.dest = dest;
            this.scaling = scaling;
            this.quality = quality;
            this.format = format;
        }
        
        public override void execute() {
            try {
                if (media is Photo)
                    ((Photo) media).export(dest, scaling, quality, format);
                else
                    ((Video) media).export(dest);
            } catch (Error err) {
                this.err = err;
            }
        }
    }
    
    private Gee.Collection<MediaSource> to_export = new Gee.ArrayList<MediaSource>();
    private File[] exported_files;
    private File? dir;
    private Scaling scaling;
    private Jpeg.Quality quality;
    private PhotoFileFormat file_format;
    private bool avoid_copying;
    private int completed_count = 0;
    private Workers workers = new Workers(Workers.threads_per_cpu(), false);
    private CompletionCallback? completion_callback = null;
    private ExportFailedCallback? error_callback = null;
    private OverwriteCallback? overwrite_callback = null;
    private ProgressMonitor? monitor = null;
    private Cancellable cancellable;
    private bool replace_all = false;
    private bool aborted = false;
    
    public Exporter(Gee.Collection<MediaSource> to_export, File? dir, Scaling scaling,
        Jpeg.Quality quality, PhotoFileFormat file_format, bool avoid_copying) {
        this.to_export.add_all(to_export);
        this.dir = dir;
        this.scaling = scaling;
        this.quality = quality;
        this.file_format = file_format;
        this.avoid_copying = avoid_copying;
    }
    
    public Exporter.for_temp_file(Gee.Collection<MediaSource> to_export, Scaling scaling,
        Jpeg.Quality quality, PhotoFileFormat file_format, bool avoid_copying) {
        this.to_export.add_all(to_export);
        this.dir = null;
        this.scaling = scaling;
        this.quality = quality;
        this.file_format = file_format;
        this.avoid_copying = avoid_copying;
    }
    
    // This should be called only once; the object does not reset its internal state when completed.
    public void export(CompletionCallback completion_callback, ExportFailedCallback error_callback,
        OverwriteCallback overwrite_callback, Cancellable? cancellable, ProgressMonitor? monitor) {
        this.completion_callback = completion_callback;
        this.error_callback = error_callback;
        this.overwrite_callback = overwrite_callback;
        this.monitor = monitor;
        this.cancellable = cancellable ?? new Cancellable();
        
        if (!process_queue())
            export_completed();
    }
    
    private void on_exported(BackgroundJob j) {
        ExportJob job = (ExportJob) j;
        
        completed_count++;
        
        // because the monitor spins the event loop, and so it's possible this function will be
        // re-entered, decide now if this is the last job
        bool completed = completed_count == to_export.size;
        
        if (!aborted && job.err != null) {
            if (!error_callback(this, job.dest, to_export.size - completed_count, job.err)) {
                aborted = true;
                
                if (!completed)
                    return;
            }
        }
        
        if (!aborted && monitor != null) {
            if (!monitor(completed_count, to_export.size)) {
                aborted = true;
                
                if (!completed)
                    return;
            } else {
                exported_files += job.dest;
            }
        }
        
        if (completed)
            export_completed();
    }
    
    private void on_export_cancelled(BackgroundJob j) {
        if (++completed_count == to_export.size)
            export_completed();
    }
    
    public File[] get_exported_files() {
        return exported_files;
    }
    
    private bool process_queue() {
        int submitted = 0;
        foreach (MediaSource source in to_export) {
            File? use_source_file = null;
            if (avoid_copying) {
                if (source is Video)
                    use_source_file = source.get_master_file();
                else if (!((Photo) source).is_export_required(scaling, file_format))
                    use_source_file = ((Photo) source).get_source_file();
            }
            
            if (use_source_file != null) {
                exported_files += use_source_file;
                
                completed_count++;
                if (monitor != null) {
                    if (!monitor(completed_count, to_export.size)) {
                        cancellable.cancel();
                        
                        return false;
                    }
                }
                
                continue;
            }
            
            File? export_dir = dir;
            File? dest = null;
            
            if (export_dir == null) {
                try {
                    bool collision;
                    dest = generate_unique_file(AppDirs.get_temp_dir(), source.get_file().get_basename(),
                        out collision);
                } catch (Error err) {
                    AppWindow.error_message(_("Unable to generate a temporary file for %s: %s").printf(
                        source.get_file().get_basename(), err.message));
                    
                    break;
                }
            } else {
                string basename = (source is Photo) 
                    ? ((Photo) source).get_export_basename(((Photo) source).get_best_export_file_format()) 
                    : ((Video) source).get_basename();
                dest = dir.get_child(basename);
                
                if (!replace_all && dest.query_exists(null)) {
                    switch (overwrite_callback(this, dest)) {
                        case Overwrite.YES:
                            // continue
                        break;
                        
                        case Overwrite.REPLACE_ALL:
                            replace_all = true;
                        break;
                        
                        case Overwrite.CANCEL:
                            cancellable.cancel();
                            
                            return false;
                        
                        case Overwrite.NO:
                        default:
                            completed_count++;
                            if (monitor != null) {
                                if (!monitor(completed_count, to_export.size)) {
                                    cancellable.cancel();
                                    
                                    return false;
                                }
                            }
                            
                            continue;
                    }
                }
            }
            
            workers.enqueue(new ExportJob(this, source, dest, scaling, quality, file_format, 
                cancellable));
            submitted++;
        }
        
        return submitted > 0;
    }
    
    private void export_completed() {
        completion_callback(this);
    }
}

public class ExporterUI {
    private Exporter exporter;
    private Cancellable cancellable = new Cancellable();
    private ProgressDialog? progress_dialog = null;
    private Exporter.CompletionCallback? completion_callback = null;
    
    public ExporterUI(Exporter exporter) {
        this.exporter = exporter;
    }
    
    public void export(Exporter.CompletionCallback completion_callback) {
        this.completion_callback = completion_callback;
        
        AppWindow.get_instance().set_busy_cursor();
        
        progress_dialog = new ProgressDialog(AppWindow.get_instance(), _("Exporting"), cancellable);
        exporter.export(on_export_completed, on_export_failed, on_export_overwrite, cancellable,
            progress_dialog.monitor);
    }
    
    private void on_export_completed(Exporter exporter) {
        if (progress_dialog != null) {
            progress_dialog.close();
            progress_dialog = null;
        }
        
        AppWindow.get_instance().set_normal_cursor();
        
        completion_callback(exporter);
    }
    
    private Exporter.Overwrite on_export_overwrite(Exporter exporter, File file) {
        string question = _("File %s already exists.  Replace?").printf(file.get_basename());
        Gtk.ResponseType response = AppWindow.negate_affirm_all_cancel_question(question, 
            _("_Skip"), _("_Replace"), _("Replace _All"), _("Export"));
        
        switch (response) {
            case Gtk.ResponseType.APPLY:
                return Exporter.Overwrite.REPLACE_ALL;
            
            case Gtk.ResponseType.YES:
                return Exporter.Overwrite.YES;
            
            case Gtk.ResponseType.CANCEL:
                return Exporter.Overwrite.CANCEL;
            
            case Gtk.ResponseType.NO:
            default:
                return Exporter.Overwrite.NO;
        }
    }
    
    private bool on_export_failed(Exporter exporter, File file, int remaining, Error err) {
        return export_error_dialog(file, remaining > 0) != Gtk.ResponseType.CANCEL;
    }
}

